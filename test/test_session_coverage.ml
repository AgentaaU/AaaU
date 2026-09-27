(* Coverage tests for [AaaU.Session] paths that the lifecycle suite does not
   reach: agent EOF cleanup, provider forwarding failures, and write-error
   handling.  These run without root by using the current account as agent. *)

open Lwt.Syntax

let () = Sys.set_signal Sys.sigpipe Sys.Signal_ignore

let () =
  (* Enable logging so the logging closures in the library are executed. *)
  Logs.set_level (Some Logs.Debug);
  Logs.set_reporter (Logs.format_reporter ())

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message
let run = Lwt_main.run

let current_account () = Unix.getpwuid (Unix.getuid ())

let user_info ?(permission = AaaU.Auth.Admin) () =
  let account = current_account () in
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

let with_audit f =
  let dir = Filename.temp_file "aaau-session-cov-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect ~finally:(fun () -> remove_tree dir) (fun () ->
      let audit = AaaU.Audit.create ~log_dir:dir in
      f audit)

let create_session ?(program = "/bin/cat") ?(args = []) ~agent_user audit =
  let session_id = Printf.sprintf "session-cov-%d" (Random.bits ()) in
  run
    (let* result =
       AaaU.Session.create ~session_id ~creator:(user_info ())
         ~agent_user ~editor_socket_path:"/tmp/aaau-session-cov-editor.sock"
         ~program ~args ~rows:24 ~cols:80 ~audit
     in
     match result with
     | Ok session -> Lwt.return session
     | Error message -> fail "Session.create failed: %s" message)

let agent_pid session =
  match AaaU.Session.get_agent_pid session with
  | Some pid -> pid
  | None -> fail "session has no agent pid"

let test_agent_eof_clears_clients () =
  with_audit (fun audit ->
      let session = create_session ~program:"/bin/true"
          ~agent_user:(current_account ()).Unix.pw_name audit in
      let server, client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* added =
           AaaU.Session.add_client session ~socket:server ~addr:"peer"
             ~user_info:(user_info ())
         in
         (match added with Ok _ -> () | Error message -> fail "%s" message);
         let deadline = Unix.gettimeofday () +. 5.0 in
         let rec wait () =
           if AaaU.Session.get_clients session = [] && not (AaaU.Session.is_alive session) then
             Lwt.return_unit
           else if Unix.gettimeofday () > deadline then Lwt.return_unit
           else
             let* () = Lwt_unix.sleep 0.05 in
             wait ()
         in
         let* () = wait () in
         expect
           (AaaU.Session.get_clients session = [])
           "agent EOF did not close client sockets";
         Lwt.catch (fun () -> Lwt_unix.close client) (fun _ -> Lwt.return_unit)))

let test_missing_account_falls_back () =
  with_audit (fun audit ->
      let session = create_session ~program:"/bin/true"
          ~agent_user:"aaau-no-such-account" audit in
      run (AaaU.Session.shutdown session))

let test_forward_editor_failures () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let pid = agent_pid session in
      let unauthorized =
        run
          (AaaU.Session.forward_editor_request session
             ~user_info:{ (user_info ()) with AaaU.Auth.uid = 987654 }
             ~peer_session_id:0 "payload")
      in
      expect (unauthorized.AaaU.Editor_protocol.status = 69)
        "editor request from a foreign account was accepted";
      let unavailable =
        run
          (AaaU.Session.forward_editor_request session
             ~user_info:(user_info ()) ~peer_session_id:pid "payload")
      in
      expect (unavailable.AaaU.Editor_protocol.status = 69)
        "editor request without a provider was accepted";
      run (AaaU.Session.shutdown session);
      let stopped =
        run
          (AaaU.Session.forward_editor_request session
             ~user_info:(user_info ()) ~peer_session_id:pid "payload")
      in
      expect (stopped.AaaU.Editor_protocol.status = 69)
        "editor request on a stopped session was accepted")

let test_forward_editor_provider () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let pid = agent_pid session in
      let provider, peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* registered =
           AaaU.Session.register_editor_provider session ~socket:provider
             ~user_info:(user_info ())
         in
         (match registered with Ok _ -> () | Error message -> fail "%s" message);
         let request =
           AaaU.Session.forward_editor_request session ~user_info:(user_info ())
             ~peer_session_id:pid "hello"
         in
         let* frame = AaaU.Editor_protocol.read_frame peer in
         let request_id =
           match frame with
           | Error message -> fail "provider read failed: %s" message
           | Ok payload ->
             (match AaaU.Editor_protocol.request_of_string payload with
              | Ok request -> request.AaaU.Editor_protocol.request_id
              | Error message -> fail "provider request parse failed: %s" message)
         in
         let reply =
           {
             AaaU.Editor_protocol.request_id;
             status = 0;
             error = None;
             content = Some "world";
           }
         in
         let* sent =
           AaaU.Editor_protocol.write_frame peer
             (AaaU.Editor_protocol.response_to_string reply)
         in
         (match sent with Ok () -> () | Error message -> fail "provider write failed: %s" message);
         let* response = request in
         expect (response.AaaU.Editor_protocol.status = 0)
           "provider exchange did not succeed";
         expect (response.AaaU.Editor_protocol.content = Some "world")
           "provider exchange returned the wrong content";
         let* () = AaaU.Session.shutdown session in
         Lwt.catch (fun () -> Lwt_unix.close peer) (fun _ -> Lwt.return_unit)))

let test_forward_editor_bad_response () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let pid = agent_pid session in
      let provider, peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* registered =
           AaaU.Session.register_editor_provider session ~socket:provider
             ~user_info:(user_info ())
         in
         (match registered with Ok _ -> () | Error message -> fail "%s" message);
         let request =
           AaaU.Session.forward_editor_request session ~user_info:(user_info ())
             ~peer_session_id:pid "hello"
         in
         let* _ = AaaU.Editor_protocol.read_frame peer in
         let* _ = AaaU.Editor_protocol.write_frame peer "not-json" in
         let* response = request in
         expect (response.AaaU.Editor_protocol.status = 69)
           "malformed provider response was accepted";
         let* () = AaaU.Session.shutdown session in
         Lwt.catch (fun () -> Lwt_unix.close peer) (fun _ -> Lwt.return_unit)))

let test_forward_editor_write_error () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let pid = agent_pid session in
      let provider, peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* registered =
           AaaU.Session.register_editor_provider session ~socket:provider
             ~user_info:(user_info ())
         in
         (match registered with Ok _ -> () | Error message -> fail "%s" message);
         (* Closing the session-side descriptor makes the request write fail. *)
         let* () = Lwt_unix.close provider in
         let* response =
           AaaU.Session.forward_editor_request session ~user_info:(user_info ())
             ~peer_session_id:pid "hello"
         in
         expect (response.AaaU.Editor_protocol.status = 69)
           "failed provider write was reported as success";
         let* () = AaaU.Session.shutdown session in
         Lwt.catch (fun () -> Lwt_unix.close peer) (fun _ -> Lwt.return_unit)))

let test_client_write_failures () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let make_client permission =
        let server, peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
        let result =
          run
            (AaaU.Session.add_client session ~socket:server ~addr:"peer"
               ~user_info:(user_info ~permission ()))
        in
        let client = match result with Ok c -> c | Error message -> fail "%s" message in
        (* Close the session-side descriptor so every reply write fails. *)
        run (Lwt_unix.close server);
        ignore peer;
        client
      in
      let readonly = make_client AaaU.Auth.ReadOnly in
      let admin = make_client AaaU.Auth.Admin in
      run
        (let* () =
           AaaU.Session.handle_client_input session ~client:readonly
             ~data:(AaaU.Protocol.encode_client (AaaU.Protocol.Input "blocked"))
         in
         let* () =
           AaaU.Session.handle_client_input session ~client:readonly
             ~data:(AaaU.Protocol.encode_client AaaU.Protocol.Ping)
         in
         let* () =
           AaaU.Session.handle_client_input session ~client:readonly
             ~data:(AaaU.Protocol.encode_client AaaU.Protocol.GetStatus)
         in
         let* () =
           AaaU.Session.handle_client_input session ~client:readonly
             ~data:(AaaU.Protocol.encode_client AaaU.Protocol.ForceKill)
         in
         let* () =
           AaaU.Session.handle_client_input session ~client:admin
             ~data:(AaaU.Protocol.encode_client (AaaU.Protocol.Input "ok"))
         in
         let* () = AaaU.Session.shutdown session in
         Lwt.return_unit))

let test_register_provider_replacement () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let first, first_peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let second, second_peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* registered =
           AaaU.Session.register_editor_provider session ~socket:first
             ~user_info:(user_info ())
         in
         let stopped = match registered with Ok stopped -> stopped | Error message -> fail "%s" message in
         let* replaced =
           AaaU.Session.register_editor_provider session ~socket:second
             ~user_info:(user_info ())
         in
         (match replaced with Ok _ -> () | Error message -> fail "%s" message);
         let* () =
           Lwt.pick
             [
               stopped;
               (let* () = Lwt_unix.sleep 1.0 in
                fail "replaced provider was not stopped");
             ]
         in
         let* () = AaaU.Session.shutdown session in
         let* () = Lwt.catch (fun () -> Lwt_unix.close first_peer) (fun _ -> Lwt.return_unit) in
         Lwt.catch (fun () -> Lwt_unix.close second_peer) (fun _ -> Lwt.return_unit)))

let test_forward_editor_read_error () =
  with_audit (fun audit ->
      let session = create_session ~agent_user:(current_account ()).Unix.pw_name audit in
      let pid = agent_pid session in
      let provider, peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      run
        (let* registered =
           AaaU.Session.register_editor_provider session ~socket:provider
             ~user_info:(user_info ())
         in
         (match registered with Ok _ -> () | Error message -> fail "%s" message);
         let request =
           AaaU.Session.forward_editor_request session ~user_info:(user_info ())
             ~peer_session_id:pid "hello"
         in
         let* _ = AaaU.Editor_protocol.read_frame peer in
         (* Closing the provider before replying makes the response read fail. *)
         let* () = Lwt_unix.close peer in
         let* response = request in
         expect (response.AaaU.Editor_protocol.status = 69)
           "provider read error was reported as success";
         let* () = AaaU.Session.shutdown session in
         Lwt.return_unit))

let test_missing_home_created () =
  with_audit (fun audit ->
      let home =
        Filename.concat (Filename.get_temp_dir_name ())
          (Printf.sprintf "aaau-missing-home-%d" (Random.bits ()))
      in
      let old_home = Sys.getenv_opt "HOME" in
      Unix.putenv "HOME" home;
      Fun.protect
        ~finally:(fun () ->
          (match old_home with Some value -> Unix.putenv "HOME" value | None -> ());
          (try Unix.rmdir home with _ -> ()))
        (fun () ->
          let session =
            create_session ~program:"/bin/true"
              ~agent_user:"aaau-no-such-account" audit
          in
          expect (Sys.file_exists home) "missing agent home was not created";
          run (AaaU.Session.shutdown session)))

let () =
  test_agent_eof_clears_clients ();
  test_missing_account_falls_back ();
  test_forward_editor_failures ();
  test_forward_editor_provider ();
  test_forward_editor_bad_response ();
  test_forward_editor_write_error ();
  test_forward_editor_read_error ();
  test_register_provider_replacement ();
  test_client_write_failures ();
  test_missing_home_created ();
  print_endline "session coverage tests passed"
