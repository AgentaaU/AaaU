open Lwt.Syntax

let fail message = prerr_endline message; exit 1
let expect condition message = if not condition then fail message

let () =
  if Unix.getuid () <> 0 then print_endline "editor session test skipped (requires root)"
  else begin
    let account = Unix.getpwuid (Unix.getuid ()) in
    let creator : AaaU.Auth.user_info = {
      username = account.Unix.pw_name; uid = account.pw_uid; gid = account.pw_gid;
      permission = AaaU.Auth.Admin;
    } in
    let audit_path = Filename.temp_file "aaau-editor-audit-" "" in
    Unix.unlink audit_path; Unix.mkdir audit_path 0o700;
    let audit = AaaU.Audit.create ~log_dir:audit_path in
    Lwt_main.run begin
      let* created = AaaU.Session.create ~session_id:"editor-test" ~creator
        ~agent_user:account.pw_name ~editor_socket_path:"/tmp/not-used"
        ~program:"/bin/sleep" ~args:["30"] ~rows:24 ~cols:80 ~audit in
      let session = match created with Ok value -> value | Error message -> fail message in
      let peer_session_id = Option.get (AaaU.Session.get_agent_pid session) in
      let* absent = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "absent" in
      expect (absent.status <> 0) "request without provider succeeded";

      let server_socket, provider_socket = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let* registered = AaaU.Session.register_editor_provider session ~socket:server_socket ~user_info:creator in
      begin match registered with Error message -> fail message | Ok _ -> () end;
      let other = { creator with AaaU.Auth.uid = creator.uid + 1; username = "other" } in
      let rejected_socket, rejected_peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
      let* rejected = AaaU.Session.register_editor_provider session ~socket:rejected_socket ~user_info:other in
      expect (Result.is_error rejected) "non-creator provider registered";
      let* () = Lwt_unix.close rejected_socket in
      let* () = Lwt_unix.close rejected_peer in

      let provider =
        let* first_payload = AaaU.Editor_protocol.read_frame provider_socket in
        let first = match first_payload with Ok value -> (match AaaU.Editor_protocol.request_of_string value with Ok request -> request | Error message -> fail message) | Error message -> fail message in
        let* early = Lwt.pick [
          (let* () = Lwt_unix.wait_read provider_socket in Lwt.return true);
          (let* () = Lwt_unix.sleep 0.05 in Lwt.return false)
        ] in
        expect (not early) "second editor request was sent before the first completed";
        let first_response = { AaaU.Editor_protocol.request_id = first.request_id; status = 0; error = None; content = Some "ONE" } in
        let* sent = AaaU.Editor_protocol.write_frame provider_socket (AaaU.Editor_protocol.response_to_string first_response) in
        begin match sent with Error message -> fail message | Ok () -> () end;
        let* second_payload = AaaU.Editor_protocol.read_frame provider_socket in
        let second = match second_payload with Ok value -> (match AaaU.Editor_protocol.request_of_string value with Ok request -> request | Error message -> fail message) | Error message -> fail message in
        let second_response = { AaaU.Editor_protocol.request_id = second.request_id; status = 5; error = Some "fake failure"; content = None } in
        let* _ = AaaU.Editor_protocol.write_frame provider_socket (AaaU.Editor_protocol.response_to_string second_response) in
        Lwt.return_unit
      in
      let first = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "one" in
      let second = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "two" in
      let* (), (first_result, second_result) = Lwt.both provider (Lwt.both first second) in
      expect (first_result.content = Some "ONE") "success content was not propagated";
      expect (second_result.status = 5) "failure status was not propagated";
      let* () = Lwt_unix.close provider_socket in
      let* disconnected = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "three" in
      expect (disconnected.status <> 0) "disconnected provider succeeded";
      AaaU.Session.shutdown session
    end;
    print_endline "editor session tests passed"
  end
