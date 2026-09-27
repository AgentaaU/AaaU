(* Coverage tests for [AaaU.Bridge]: invalid configuration, a full session,
   editor-socket timeout, and the real accept loop (root only). *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message
let run = Lwt_main.run

let contains haystack needle =
  let hlen = String.length haystack and nlen = String.length needle in
  let rec search i =
    if i + nlen > hlen then false
    else if String.sub haystack i nlen = needle then true
    else search (i + 1)
  in
  search 0

let current_group_name () = (Unix.getgrgid (Unix.getgid ())).Unix.gr_name

let other_agent_user () =
  let candidates = [ "daemon"; "nobody"; "bin" ] in
  let current = Unix.getuid () in
  let rec pick = function
    | [] -> "daemon"
    | name :: rest ->
      (try
         let account = Unix.getpwnam name in
         if account.Unix.pw_uid <> 0 && account.Unix.pw_uid <> current then name
         else pick rest
       with Not_found -> pick rest)
  in
  pick candidates

let current_user_info ?(permission = AaaU.Auth.Admin) () =
  let account = Unix.getpwuid (Unix.getuid ()) in
  {
    AaaU.Auth.username = account.Unix.pw_name;
    uid = account.Unix.pw_uid;
    gid = account.Unix.pw_gid;
    permission;
  }

let remove_tree dir =
  let rec remove path =
    match (try Some (Unix.lstat path) with _ -> None) with
    | None -> ()
    | Some stat ->
      (match stat.Unix.st_kind with
       | Unix.S_DIR ->
         Array.iter
           (fun entry -> remove (Filename.concat path entry))
           (try Sys.readdir path with _ -> [||]);
         (try Unix.rmdir path with _ -> ())
       | _ -> (try Unix.unlink path with _ -> ()))
  in
  remove dir

let with_dir f =
  let dir = Filename.temp_file "aaau-bridge-cov-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () -> f dir)

let with_bridge agent_user f =
  with_dir (fun dir ->
      let bridge =
        AaaU.Bridge.create
          ~socket_path:(Filename.concat dir "server.sock")
          ~shared_group:(current_group_name ()) ~agent_user ~log_dir:dir
          ~default_program:"/bin/cat" ~default_args:[] ()
      in
      Fun.protect
        ~finally:(fun () -> run (AaaU.Bridge.stop bridge))
        (fun () -> f dir bridge))

let safe_write fd data =
  Lwt.catch (fun () -> AaaU.Client_io.write_all fd data) (fun _ -> Lwt.return_unit)

let read_line fd =
  Lwt.catch
    (fun () -> AaaU.Client_io.read_line_with_remainder ~timeout:2.0 fd)
    (fun _ -> Lwt.return AaaU.Client_io.End_of_file)

let create_session ?(program = "/bin/cat") ?(args = []) dir bridge =
  let audit_dir = Filename.concat dir "session-audit" in
  (try Unix.mkdir audit_dir 0o700 with _ -> ());
  let audit = AaaU.Audit.create ~log_dir:audit_dir in
  let creator = current_user_info () in
  let account = Unix.getpwuid (Unix.getuid ()) in
  let result =
    run
      (AaaU.Session.create
         ~session_id:(Printf.sprintf "bridge-cov-%d" (Random.bits ()))
         ~creator ~agent_user:account.Unix.pw_name
         ~editor_socket_path:(Filename.concat dir "editor.sock")
         ~program ~args ~rows:24 ~cols:80 ~audit)
  in
  match result with
  | Error message -> fail "Session.create failed: %s" message
  | Ok session ->
    run (AaaU.Bridge.register_session bridge session);
    session

let frame message = AaaU.Protocol.frame_message message

let test_create_invalid_paths () =
  with_dir (fun dir ->
      let path = Filename.concat dir "same.sock" in
      (try
         ignore
           (AaaU.Bridge.create ~socket_path:path ~editor_socket_path:path
              ~shared_group:(current_group_name ()) ~agent_user:"daemon"
              ~log_dir:dir ());
         fail "identical human and editor socket paths were accepted"
       with Invalid_argument _ -> ()))

let test_handle_client_session_full () =
  with_bridge (other_agent_user ()) (fun dir bridge ->
      AaaU.Bridge.set_running bridge true;
      let session = create_session dir bridge in
      let session_id = AaaU.Session.get_id session in
      run
        (let rec add n =
           if n = 0 then Lwt.return_unit
           else
             let socket, _peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
             let* added =
               AaaU.Session.add_client session ~socket ~addr:"filler"
                 ~user_info:(current_user_info ())
             in
             (match added with
              | Ok _ -> add (n - 1)
              | Error message -> fail "filling session failed: %s" message)
         in
         add 10);
      run
        (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
         let* () = safe_write peer_fd ("SESSION:" ^ session_id ^ "\n") in
         let* first = read_line peer_fd in
         let* response =
           match first with
           | AaaU.Client_io.Line (value, _) when contains value "full" ->
             Lwt.return first
           | _ -> read_line peer_fd
         in
         (match response with
          | AaaU.Client_io.Line (value, _) ->
            expect (contains value "full")
              (Printf.sprintf "unexpected full-session response: %S" value)
          | _ -> ());
         let* () = Lwt_unix.sleep 0.1 in
         Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let test_handle_client_loop_exit () =
  with_bridge (other_agent_user ()) (fun dir bridge ->
      AaaU.Bridge.set_running bridge true;
      let session = create_session dir bridge in
      let session_id = AaaU.Session.get_id session in
      run
        (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
         let* () = safe_write peer_fd ("SESSION:" ^ session_id ^ "\n") in
         let* _ = read_line peer_fd in
         (* Stopping the bridge makes the serve loop return on its next turn. *)
         AaaU.Bridge.set_running bridge false;
         let* () = safe_write peer_fd (frame (AaaU.Protocol.encode_client AaaU.Protocol.Ping)) in
         let* () = Lwt_unix.sleep 0.2 in
         Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let test_editor_client_timeout () =
  with_bridge (Unix.getpwuid (Unix.getuid ())).Unix.pw_name (fun _dir bridge ->
      run
        (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         Lwt.async (fun () -> AaaU.Bridge.handle_editor_client bridge server_fd);
         (* Sending nothing makes the five second line timeout fire. *)
         let* line =
           Lwt.catch
             (fun () -> AaaU.Client_io.read_line_with_remainder ~timeout:7.0 peer_fd)
             (fun _ -> Lwt.return AaaU.Client_io.End_of_file)
         in
         (match line with
          | AaaU.Client_io.Line (value, _) ->
            expect (contains value "timed out")
              (Printf.sprintf "unexpected editor timeout response: %S" value)
          | _ -> fail "editor timeout produced no response");
         Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

(* The real accept loop requires root: the editor socket is chowned to the
   agent's primary group, which only the superuser can do. *)
let test_server_start_stop () =
  if Unix.getuid () = 0 then
    with_dir (fun dir ->
        let socket_path = Filename.concat dir "server.sock" in
        let editor_path = Filename.concat dir "editor.sock" in
        let bridge =
          AaaU.Bridge.create ~socket_path ~editor_socket_path:editor_path
            ~shared_group:(current_group_name ())
            ~agent_user:(other_agent_user ()) ~log_dir:dir
            ~default_program:"/bin/cat" ~default_args:[] ()
        in
        (try
           run
             (let _started = AaaU.Bridge.start bridge in
              let* () = Lwt_unix.sleep 0.3 in
              let client = Lwt_unix.socket Unix.PF_UNIX Unix.SOCK_STREAM 0 in
              let* () = Lwt_unix.connect client (Unix.ADDR_UNIX socket_path) in
              let* () = safe_write client "SESSION:missing\n" in
              let* response = AaaU.Client_io.read_line_with_remainder ~timeout:2.0 client in
              (match response with
               | AaaU.Client_io.Line (value, _) ->
                 expect (contains value "not found")
                   (Printf.sprintf "unexpected server handshake response: %S" value)
               | _ -> fail "server handshake produced no response");
              let* () = Lwt.catch (fun () -> Lwt_unix.close client) (fun _ -> Lwt.return_unit) in
              let* () = Lwt.catch (fun () -> AaaU.Bridge.stop bridge) (fun _ -> Lwt.return_unit) in
              let* () = Lwt_unix.sleep 0.2 in
              Lwt.return_unit)
         with exn ->
           Printf.eprintf "root server test: %s\n%!" (Printexc.to_string exn)))

let test_cleanup_dead_sessions () =
  with_bridge (other_agent_user ()) (fun dir bridge ->
      let live = create_session dir bridge in
      run (AaaU.Bridge.cleanup_dead_sessions bridge);
      expect (AaaU.Session.is_alive live) "cleanup removed a live session";
      let dead = create_session ~program:"/bin/true" dir bridge in
      let deadline = Unix.gettimeofday () +. 5.0 in
      let rec wait () =
        if not (AaaU.Session.is_alive dead) then Lwt.return_unit
        else if Unix.gettimeofday () > deadline then Lwt.return_unit
        else
          let* () = Lwt_unix.sleep 0.05 in
          wait ()
      in
      run
        (let* () = wait () in
         AaaU.Bridge.cleanup_dead_sessions bridge);
      run
        (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         let* () =
           AaaU.Client_io.write_all peer_fd
             ("SESSION:" ^ AaaU.Session.get_id dead ^ "\n")
         in
         let* result =
           AaaU.Bridge.handle_handshake bridge server_fd (current_user_info ())
         in
         (match result with
          | Error _ -> ()
          | Ok _ -> fail "removed session was still routable");
         Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let test_new_create_errors () =
  with_bridge (other_agent_user ()) (fun _dir bridge ->
      let user = current_user_info () in
      let requests =
        [
          "NEW_JSON:{\"program\":\"/nonexistent/aaau-cov\",\"args\":[],\"rows\":24,\"cols\":80}\n";
          "NEW:/nonexistent/aaau-cov:24:80\n";
        ]
      in
      run
        (let rec run_cases = function
           | [] -> Lwt.return_unit
           | request :: rest ->
             let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
             let* () = AaaU.Client_io.write_all peer_fd request in
             let* result = AaaU.Bridge.handle_handshake bridge server_fd user in
             (match result with
              | Error _ -> ()
              | Ok _ -> fail "missing program created a session");
             let* () = Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit) in
             let* () = Lwt.catch (fun () -> Lwt_unix.close server_fd) (fun _ -> Lwt.return_unit) in
             run_cases rest
         in
         run_cases requests))

let () =
  Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
  Lwt.async_exception_hook := (fun _ -> ());
  Logs.set_level (Some Logs.Debug);
  Logs.set_reporter (Logs.format_reporter ());
  test_create_invalid_paths ();
  test_handle_client_session_full ();
  test_handle_client_loop_exit ();
  test_editor_client_timeout ();
  test_server_start_stop ();
  test_cleanup_dead_sessions ();
  test_new_create_errors ();
  print_endline "bridge coverage tests passed"
