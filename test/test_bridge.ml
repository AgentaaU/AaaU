(** Unprivileged tests for [AaaU.Bridge].

    The real server can only start after switching to the agent account, which
    requires root, so these tests drive the exposed handshake/authentication
    helpers directly with socketpairs.  That covers the parser and the success
    and failure branches of the connection setup without privileges. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let contains haystack needle =
  let haystack_len = String.length haystack and needle_len = String.length needle in
  let rec search index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else search (index + 1)
  in
  search 0

let current_group_name () = (Unix.getgrgid (Unix.getgid ())).Unix.gr_name

let other_agent_user () =
  let candidates = [ "daemon"; "nobody"; "bin" ] in
  let current = Unix.getuid () in
  let rec pick = function
    | [] -> "daemon"
    | name :: rest ->
      begin
        try
          let account = Unix.getpwnam name in
          if account.Unix.pw_uid <> 0 && account.Unix.pw_uid <> current then name
          else pick rest
        with Not_found -> pick rest
      end
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
      begin
        match stat.Unix.st_kind with
        | Unix.S_DIR ->
          Array.iter
            (fun entry -> remove (Filename.concat path entry))
            (try Sys.readdir path with _ -> [||]);
          (try Unix.rmdir path with _ -> ())
        | _ -> (try Unix.unlink path with _ -> ())
      end
  in
  remove dir

let with_bridge agent_user f =
  let dir = Filename.temp_file "aaau-bridge-test-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  let log_dir = Filename.concat dir "logs" in
  let bridge =
    AaaU.Bridge.create
      ~socket_path:(Filename.concat dir "server.sock")
      ~shared_group:(current_group_name ()) ~agent_user ~log_dir
      ~default_program:"/bin/true" ()
  in
  Fun.protect
    ~finally:(fun () ->
      Lwt_main.run (AaaU.Bridge.stop bridge);
      remove_tree dir)
    (fun () -> f dir bridge)

let read_line fd =
  let* result = AaaU.Client_io.read_line_with_remainder ~timeout:0.5 fd in
  match result with
  | AaaU.Client_io.Line (line, _) -> Lwt.return (Some line)
  | AaaU.Client_io.End_of_file -> Lwt.return (Some "")
  | AaaU.Client_io.Timeout_line -> Lwt.return None

(* Send a handshake from the peer side and return the result together with any
   line the server wrote back. *)
let exchange bridge user_info request =
  let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  let* () = AaaU.Client_io.write_all peer_fd request in
  let* result =
    Lwt.catch
      (fun () -> AaaU.Bridge.handle_handshake bridge server_fd user_info)
      (fun exn -> Lwt.return (Error (Printexc.to_string exn)))
  in
  let* response = read_line peer_fd in
  let* () = Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit) in
  let* () = Lwt.catch (fun () -> Lwt_unix.close server_fd) (fun _ -> Lwt.return_unit) in
  match result with
  | Error message -> Lwt.return (`Error message, response)
  | Ok (`New (session, remaining)) ->
    Lwt.return (`New (session, remaining), response)
  | Ok (`Existing (session, remaining)) ->
    Lwt.return (`Existing (session, remaining), response)
  | Ok (`Dedicated _) -> Lwt.return (`Dedicated, response)

let test_parse_new_json () =
  let valid =
    "{\"program\":\"/bin/echo\",\"args\":[\"a\",\"b\"],\"rows\":24,\"cols\":80}"
  in
  (match AaaU.Bridge.parse_new_json valid with
  | Ok ("/bin/echo", [ "a"; "b" ], 24, 80) -> ()
  | _ -> fail "valid NEW_JSON payload was not parsed");
  let failures =
    [
      "{}";
      "{\"program\":\"/bin/echo\",\"args\":[],\"rows\":24}";
      "{\"program\":\"/bin/echo\",\"args\":\"nope\",\"rows\":24,\"cols\":80}";
      "{\"program\":\"/bin/echo\",\"args\":[1],\"rows\":24,\"cols\":80}";
      "{\"program\":\"/bin/echo\",\"args\":[],\"rows\":0,\"cols\":80}";
      "{\"program\":\"/bin/echo\",\"args\":[],\"rows\":24,\"cols\":1001}";
      "[]";
      "not-json";
    ]
  in
  List.iter
    (fun payload ->
      let parsed =
        try AaaU.Bridge.parse_new_json payload
        with _ -> Error "raised"
      in
      match parsed with
      | Ok _ -> fail "invalid payload accepted: %s" payload
      | Error _ -> ())
    failures

let test_authenticate_client () =
  with_bridge (other_agent_user ()) (fun _dir bridge ->
    let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt_main.run
      (let* result = AaaU.Bridge.authenticate_client bridge server_fd in
       (match result with
        | Ok user -> expect (user.AaaU.Auth.uid = Unix.getuid ()) "peer uid mismatch"
        | Error message -> fail "expected authentication to succeed: %s" message);
       let* () = Lwt_unix.close peer_fd in
       Lwt_unix.close server_fd));
  with_bridge (Unix.getpwuid (Unix.getuid ())).Unix.pw_name (fun _dir bridge ->
    let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt_main.run
      (let* result = AaaU.Bridge.authenticate_client bridge server_fd in
       (match result with
        | Ok _ -> fail "agent account was allowed on the human socket"
        | Error message ->
          expect (contains message "denied")
            (Printf.sprintf "unexpected denial message: %s" message));
       let* () = Lwt_unix.close peer_fd in
       Lwt_unix.close server_fd))

let test_handshake_failures bridge =
  let user = current_user_info () in
  let cases =
    [
      ("SESSION:does-not-exist\n", "not found");
      ("EDITOR_PROVIDER:does-not-exist\n", "not found");
      ("definitely-not-a-command\n", "Invalid handshake");
      ("NEW_JSON:{\"program\":\"/bin/true\",\"rows\":24,\"cols\":80}\n", "args");
      ("NEW_JSON:{\"program\":\"/bin/true\",\"args\":[],\"rows\":0,\"cols\":80}\n", "dimensions");
      ("NEW_JSON:not-json\n", "Json");
    ]
  in
  Lwt_main.run
    (let rec run = function
       | [] -> Lwt.return_unit
       | (request, expected) :: rest ->
         let* result, _response = exchange bridge user request in
         (match result with
          | `Error message ->
            expect (contains message expected)
              (Printf.sprintf "unexpected error for %S: %s" request message)
          | _ -> fail "request unexpectedly succeeded: %S" request);
         run rest
     in
     run cases)

(* Build a session through the NEW handshake so later cases can exercise the
   SESSION and EDITOR_PROVIDER success branches. *)
let test_handshake_success bridge =
  let user = current_user_info () in
  Lwt_main.run
    (let* result, response = exchange bridge user "NEW:24:80\n" in
     let session = match result with
       | `New (session, remaining) ->
         expect (remaining = "") "NEW handshake left unexpected trailing bytes";
         session
       | _ -> fail "NEW handshake did not create a session"
     in
     let response = match response with Some line -> line | None -> fail "NEW handshake produced no response" in
     let session_id = AaaU.Session.get_id session in
     expect
       (response = "SESSION:" ^ session_id)
       (Printf.sprintf "unexpected NEW response: %S" response);

     (* Rejoining the session exercises the SESSION success branch. *)
     let* joined, join_response = exchange bridge user ("SESSION:" ^ session_id ^ "\n") in
     (match joined with
      | `Existing (joined_session, _) ->
        expect
          (AaaU.Session.get_id joined_session = session_id)
          "joined the wrong session"
      | _ -> fail "SESSION handshake did not return the existing session");
     (match join_response with
      | Some line ->
        expect
          (line = "SESSION:" ^ session_id)
          (Printf.sprintf "unexpected SESSION response: %S" line)
      | None -> fail "SESSION handshake produced no response");

     (* Registering an editor provider on the session exercises that branch. *)
     let* dedicated, provider_response =
       exchange bridge user ("EDITOR_PROVIDER:" ^ session_id ^ "\n")
     in
     (match dedicated with
      | `Dedicated -> ()
      | _ -> fail "EDITOR_PROVIDER handshake did not dedicate the connection");
     (match provider_response with
      | Some line ->
        expect
          (line = "EDITOR_PROVIDER:" ^ session_id)
          (Printf.sprintf "unexpected provider response: %S" line)
      | None -> fail "EDITOR_PROVIDER handshake produced no response");

     (* Trailing bytes after a provider handshake are rejected. *)
     let* result, _ = exchange bridge user ("EDITOR_PROVIDER:" ^ session_id ^ "\nextra") in
     (match result with
      | `Error message ->
        expect (contains message "Unexpected bytes")
          (Printf.sprintf "unexpected trailing-bytes error: %s" message)
      | _ -> fail "trailing bytes after EDITOR_PROVIDER were accepted");

     (* A non-creator cannot register as provider. *)
     let other = { user with AaaU.Auth.uid = user.AaaU.Auth.uid + 1 } in
     let* result, _ = exchange bridge other ("EDITOR_PROVIDER:" ^ session_id ^ "\n") in
     (match result with
      | `Error _ -> ()
      | _ -> fail "non-creator provider registration was accepted");

     Lwt.return_unit)

let test_new_variants bridge =
  let user = current_user_info () in
  let requests =
    [
      "NEW:/bin/true:24:80\n";
      "NEW:/bin/echo:hello:24:80\n";
      "NEW:/bin/echo:not:numbers\n";
      "NEW:/bin/echo\n";
      "NEW:\n";
      "NEW_JSON:{\"program\":\"/bin/true\",\"args\":[],\"rows\":24,\"cols\":80}\n";
    ]
  in
  Lwt_main.run
    (let rec run = function
       | [] -> Lwt.return_unit
       | request :: rest ->
         let* result, response = exchange bridge user request in
         (match result with
          | `New _ -> ()
          | _ -> fail "NEW variant did not create a session: %S" request);
         (match response with
          | Some line ->
            expect
              (String.starts_with ~prefix:"SESSION:" line)
              (Printf.sprintf "unexpected NEW variant response: %S" line)
          | None -> fail "NEW variant produced no response: %S" request);
         run rest
     in
     run requests)

let test_handshake_eof bridge =
  let user = current_user_info () in
  Lwt_main.run
    (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* () = Lwt_unix.close peer_fd in
     let* result = AaaU.Bridge.handle_handshake bridge server_fd user in
     (match result with
      | Error message ->
        expect (contains message "closed") (Printf.sprintf "unexpected EOF error: %s" message)
      | _ -> fail "EOF handshake unexpectedly succeeded");
     Lwt_unix.close server_fd)

let read_some fd ~timeout =
  Lwt.pick
    [
      (let buffer = Bytes.create 8192 in
       let+ count = Lwt_unix.read fd buffer 0 8192 in
       Bytes.sub_string buffer 0 count);
      (let* () = Lwt_unix.sleep timeout in
       Lwt.return "");
    ]

let wait_for fd ~substring ~timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec loop acc =
    if contains acc substring || Unix.gettimeofday () > deadline then Lwt.return acc
    else
      let* chunk = read_some fd ~timeout:(max 0.05 (deadline -. Unix.gettimeofday ())) in
      loop (acc ^ chunk)
  in
  loop ""

let create_session dir bridge =
  let audit_dir = Filename.concat dir "session-audit" in
  (try Unix.mkdir audit_dir 0o700 with _ -> ());
  let audit = AaaU.Audit.create ~log_dir:audit_dir in
  let creator = current_user_info () in
  let account = Unix.getpwuid (Unix.getuid ()) in
  let result =
    Lwt_main.run
      (AaaU.Session.create
         ~session_id:(Printf.sprintf "bridge-session-%d" (Random.bits ()))
         ~creator ~agent_user:account.Unix.pw_name
         ~editor_socket_path:(Filename.concat dir "editor.sock")
         ~program:"/bin/cat" ~args:[] ~rows:24 ~cols:80 ~audit)
  in
  match result with
  | Error message -> fail "Session.create failed: %s" message
  | Ok session ->
    Lwt_main.run (AaaU.Bridge.register_session bridge session);
    session

let frame message = AaaU.Protocol.frame_message message

let test_handle_client_auth_failure () =
  with_bridge (Unix.getpwuid (Unix.getuid ())).Unix.pw_name (fun _dir bridge ->
    Lwt_main.run
      (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
       let* line = read_line peer_fd in
       (match line with
        | Some value ->
          expect
            (String.starts_with ~prefix:"Auth failed" value)
            (Printf.sprintf "unexpected auth response: %S" value)
        | None -> fail "auth failure produced no response");
       Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let test_handle_client_handshake_error () =
  with_bridge (other_agent_user ()) (fun _dir bridge ->
    Lwt_main.run
      (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
       let* () = AaaU.Client_io.write_all peer_fd "SESSION:missing\n" in
       let* line = read_line peer_fd in
       (match line with
        | Some value ->
          expect (contains value "not found")
            (Printf.sprintf "unexpected handshake error: %S" value)
        | None -> fail "handshake error produced no response");
       Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let test_handle_client_success dir bridge =
  AaaU.Bridge.set_running bridge true;
  let session = create_session dir bridge in
  let session_id = AaaU.Session.get_id session in
  Lwt_main.run
    (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
     let* () = AaaU.Client_io.write_all peer_fd ("SESSION:" ^ session_id ^ "\n") in
     let* line = read_line peer_fd in
     (match line with
      | Some value ->
        expect
          (value = "SESSION:" ^ session_id)
          (Printf.sprintf "unexpected join response: %S" value)
      | None -> fail "join produced no response");

     (* Ping is answered directly by the session. *)
     let* () = AaaU.Client_io.write_all peer_fd (frame (AaaU.Protocol.encode_client AaaU.Protocol.Ping)) in
     let* pong = wait_for peer_fd ~substring:"\x01PONG" ~timeout:2.0 in
     expect (contains pong "\x01PONG") "ping was not answered through the bridge";

     (* Input reaches the PTY and the echo is broadcast. *)
     let* () = AaaU.Client_io.write_all peer_fd (frame (AaaU.Protocol.encode_client (AaaU.Protocol.Input "bridge-hello\n"))) in
     let* echo = wait_for peer_fd ~substring:"bridge-hello" ~timeout:5.0 in
     expect (contains echo "bridge-hello") "input was not echoed back";

     (* Status and resize are handled. *)
     let* () = AaaU.Client_io.write_all peer_fd (frame (AaaU.Protocol.encode_client AaaU.Protocol.GetStatus)) in
     let* status = wait_for peer_fd ~substring:"session_id" ~timeout:2.0 in
     expect (contains status "session_id") "status was not reported through the bridge";
     let* () = AaaU.Client_io.write_all peer_fd (frame (AaaU.Protocol.encode_client (AaaU.Protocol.Resize { rows = 30; cols = 100 }))) in
     let* () = AaaU.Client_io.write_all peer_fd (frame "\x01NOT_A_COMMAND") in
     let* () = Lwt_unix.sleep 0.1 in

     (* Disconnecting removes the client and returns the served promise. *)
     let* () = Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit) in
     Lwt.return_unit)

let test_handle_client_oversized_frame dir bridge =
  AaaU.Bridge.set_running bridge true;
  let session = create_session dir bridge in
  let session_id = AaaU.Session.get_id session in
  Lwt_main.run
    (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     Lwt.async (fun () -> AaaU.Bridge.handle_client bridge server_fd "peer");
     let* () = AaaU.Client_io.write_all peer_fd ("SESSION:" ^ session_id ^ "\n") in
     let* _ = read_line peer_fd in
     let header = Bytes.make 4 '\000' in
     Bytes.set_int32_be header 0 (Int32.of_int AaaU.Protocol.max_frame_size);
     let* () =
       Lwt.catch
         (fun () ->
           let* () = AaaU.Client_io.write_all peer_fd (Bytes.unsafe_to_string header) in
           AaaU.Client_io.write_all peer_fd
             (String.make (AaaU.Protocol.max_frame_size + 1) 'x'))
         (fun _ -> Lwt.return_unit)
     in
     let* line = read_line peer_fd in
     (match line with
      | Some value ->
        expect
          (contains value "maximum size")
          (Printf.sprintf "unexpected oversized-frame response: %S" value)
      | None -> fail "oversized frame produced no response");
     Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit))

let test_handle_editor_client dir bridge =
  let session = create_session dir bridge in
  let session_id = AaaU.Session.get_id session in
  let run_request request =
    let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
    Lwt.async (fun () -> AaaU.Bridge.handle_editor_client bridge server_fd);
    let* () = AaaU.Client_io.write_all peer_fd request in
    let* line = read_line peer_fd in
    let* () = Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit) in
    Lwt.return line
  in
  Lwt_main.run
    (let* not_found = run_request "EDITOR_REQUEST:missing\n" in
     (match not_found with
      | Some value ->
        expect (contains value "not found")
          (Printf.sprintf "unexpected editor response: %S" value)
      | None -> fail "editor request produced no response");
     let* unauthorized = run_request ("EDITOR_REQUEST:" ^ session_id ^ "\n") in
     (match unauthorized with
      | Some value ->
        expect (contains value "does not belong")
          (Printf.sprintf "unexpected editor response: %S" value)
      | None -> fail "editor request produced no response");
     let* wrong = run_request "HELLO\n" in
     (match wrong with
      | Some value ->
        expect (contains value "only EDITOR_REQUEST")
          (Printf.sprintf "unexpected editor response: %S" value)
      | None -> fail "wrong editor request produced no response");
     (* Closing without a request exercises the EOF path. *)
     let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     Lwt.async (fun () -> AaaU.Bridge.handle_editor_client bridge server_fd);
     let* () = Lwt_unix.close peer_fd in
     let* () = Lwt_unix.sleep 0.1 in
     Lwt.catch (fun () -> Lwt_unix.close server_fd) (fun _ -> Lwt.return_unit))

let test_handle_editor_auth_failure () =
  with_bridge (other_agent_user ()) (fun _dir bridge ->
    Lwt_main.run
      (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
       Lwt.async (fun () -> AaaU.Bridge.handle_editor_client bridge server_fd);
       let* line = read_line peer_fd in
       (match line with
        | Some value ->
          expect
            (String.starts_with ~prefix:"Auth failed" value)
            (Printf.sprintf "unexpected editor auth response: %S" value)
        | None -> fail "editor auth failure produced no response");
       Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit)))

let () =
  test_parse_new_json ();
  with_bridge (Unix.getpwuid (Unix.getuid ())).Unix.pw_name (fun dir bridge ->
    test_handshake_failures bridge;
    test_handshake_success bridge;
    test_new_variants bridge;
    test_handshake_eof bridge;
    test_handle_editor_client dir bridge);
  test_handle_client_auth_failure ();
  test_handle_client_handshake_error ();
  test_handle_editor_auth_failure ();
  with_bridge (other_agent_user ()) (fun dir bridge ->
    test_handle_client_success dir bridge;
    test_handle_client_oversized_frame dir bridge);
  test_authenticate_client ();
  print_endline "bridge tests passed"
