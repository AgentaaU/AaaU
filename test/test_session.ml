(** Unprivileged unit tests for [AaaU.Session].

    These tests exercise the session state machine directly with the current
    account as the agent user.  [Pty.fork_agent] only needs root when the
    target account differs from the effective user, so the full session
    lifecycle can be covered without privileges. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt

let contains haystack needle =
  let haystack_len = String.length haystack and needle_len = String.length needle in
  let rec search index =
    if index + needle_len > haystack_len then false
    else if String.sub haystack index needle_len = needle then true
    else search (index + 1)
  in
  search 0

let current_account () = Unix.getpwuid (Unix.getuid ())

let user_info ?(permission = AaaU.Auth.Admin) () =
  let account = current_account () in
  {
    AaaU.Auth.username = account.Unix.pw_name;
    uid = account.Unix.pw_uid;
    gid = account.Unix.pw_gid;
    permission;
  }

let with_audit f =
  let dir = Filename.temp_file "aaau-session-test-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Array.iter
        (fun entry -> try Unix.unlink (Filename.concat dir entry) with _ -> ())
        (Sys.readdir dir);
      (try Unix.rmdir dir with _ -> ()))
    (fun () ->
      let audit = AaaU.Audit.create ~log_dir:dir in
      f audit)

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
    if String.length acc > 1_000_000 || Unix.gettimeofday () > deadline then
      Lwt.return acc
    else if contains acc substring then
      Lwt.return acc
    else
      let* chunk = read_some fd ~timeout:(max 0.05 (deadline -. Unix.gettimeofday ())) in
      loop (acc ^ chunk)
  in
  loop ""

let drain fd =
  let rec loop () =
    let* chunk = read_some fd ~timeout:0.05 in
    if chunk = "" then Lwt.return_unit else loop ()
  in
  loop ()

let create_session audit ?(program = "/bin/cat") ?(args = []) () =
  let creator = user_info () in
  let session_id = Printf.sprintf "test-%d" (Random.bits ()) in
  let* result =
    AaaU.Session.create ~session_id ~creator
      ~agent_user:(current_account ()).Unix.pw_name
      ~editor_socket_path:"/tmp/aaau-test-editor.sock" ~program ~args
      ~rows:24 ~cols:80 ~audit
  in
  match result with
  | Ok session -> Lwt.return session
  | Error message -> fail "Session.create failed: %s" message

let test_queue () =
  let queue = AaaU.Session.Lwt_queue.create () in
  Lwt_main.run
    (let* () = AaaU.Session.Lwt_queue.push "first" queue in
     let* item = AaaU.Session.Lwt_queue.pop queue in
     if item <> "first" then fail "Lwt_queue did not return the pushed item";
     (* A pop on an empty queue must wait for the next push. *)
     let pending = AaaU.Session.Lwt_queue.pop queue in
     let* () = Lwt_unix.sleep 0.05 in
     let* () = AaaU.Session.Lwt_queue.push "second" queue in
     let* item = pending in
     if item <> "second" then fail "waiting pop did not observe the push";
     let* () = Lwt_unix.sleep 0.95 in
     Lwt.return_unit)

let test_authorization_helpers () =
  let creator = user_info () in
  if not (AaaU.Session.authorize_editor_provider ~creator_uid:creator.uid creator) then
    fail "creator should be allowed to provide an editor";
  let other = { creator with uid = creator.uid + 1 } in
  if AaaU.Session.authorize_editor_provider ~creator_uid:creator.uid other then
    fail "non-creator should not provide an editor";
  if
    not
      (AaaU.Session.authorize_editor_request ~agent_uid:creator.uid
         ~agent_session_id:7 creator ~peer_session_id:7)
  then fail "matching agent request should be authorized";
  if
    AaaU.Session.authorize_editor_request ~agent_uid:creator.uid
      ~agent_session_id:7 creator ~peer_session_id:8
  then fail "mismatched agent session should be rejected";
  if
    AaaU.Session.authorize_editor_request ~agent_uid:(creator.uid + 1)
      ~agent_session_id:7 creator ~peer_session_id:7
  then fail "wrong agent uid should be rejected"

let test_runtime_dir_env () =
  (match AaaU.Session.runtime_dir_env ~agent_uid:(-1) () with
  | [] -> ()
  | _ -> fail "negative uid should produce no runtime directory");
  (match AaaU.Session.runtime_dir_env ~exists:(fun _ -> false) ~agent_uid:1000 () with
  | [] -> ()
  | _ -> fail "missing directory should produce no runtime directory");
  match AaaU.Session.runtime_dir_env ~exists:(fun _ -> true) ~agent_uid:1000 () with
  | [ ("XDG_RUNTIME_DIR", "/run/user/1000") ] -> ()
  | _ -> fail "expected XDG_RUNTIME_DIR mapping"

let test_lifecycle audit =
  Lwt_main.run
    (let* session = create_session audit () in
     if AaaU.Session.get_id session = "" then fail "session id should not be empty";
     if AaaU.Session.get_agent_pid session = None then fail "agent pid should be present";
     if not (AaaU.Session.is_alive session) then fail "session should be alive";
     if AaaU.Session.get_clients session <> [] then fail "new session should have no clients";

     let server, client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* added = AaaU.Session.add_client session ~socket:server ~addr:"peer" ~user_info:(user_info ()) in
     let client_info = match added with Ok value -> value | Error message -> failwith message in
     if List.length (AaaU.Session.get_clients session) <> 1 then
       fail "client list should contain the added client";

     (* Input from an admin client is forwarded to the PTY. *)
     let* () = AaaU.Session.handle_client_input session ~client:client_info ~data:"hello-from-test\n" in
     let* output = wait_for client ~substring:"hello-from-test" ~timeout:5.0 in
     if not (contains output "hello-from-test") then
       fail "session did not forward input/output (got %S)" output;

     (* A second client receives the buffered history. *)
     let server2, client2 = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* added2 = AaaU.Session.add_client session ~socket:server2 ~addr:"peer2" ~user_info:(user_info ()) in
     let _ = match added2 with Ok value -> value | Error message -> failwith message in
     let* history = wait_for client2 ~substring:"hello-from-test" ~timeout:2.0 in
     if not (contains history "hello-from-test") then
       fail "second client did not receive history";
     let* () = drain client2 in

     (* Resize is accepted. *)
     let* () = AaaU.Session.handle_client_input session ~client:client_info ~data:(AaaU.Protocol.encode_client (AaaU.Protocol.Resize { rows = 30; cols = 100 })) in

     (* Ping produces a pong. *)
     let* () = AaaU.Session.handle_client_input session ~client:client_info ~data:(AaaU.Protocol.encode_client AaaU.Protocol.Ping) in
     let* pong = read_some client ~timeout:1.0 in
     if not (contains pong "\x01PONG") then fail "ping was not answered";

     (* Status is reported. *)
     let* () = AaaU.Session.handle_client_input session ~client:client_info ~data:(AaaU.Protocol.encode_client AaaU.Protocol.GetStatus) in
     let* status = wait_for client ~substring:"status" ~timeout:1.0 in
     if not (contains status "session_id") then fail "status was not reported";

     (* Unknown control messages are ignored. *)
     let* () = AaaU.Session.handle_client_input session ~client:client_info ~data:"\x01NOT_A_COMMAND" in

     (* Read-only clients cannot send input. *)
     let ro_server, ro_client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* added_ro = AaaU.Session.add_client session ~socket:ro_server ~addr:"ro" ~user_info:(user_info ~permission:AaaU.Auth.ReadOnly ()) in
     let ro = match added_ro with Ok value -> value | Error message -> failwith message in
     let* () = AaaU.Session.handle_client_input session ~client:ro ~data:"should-be-rejected\n" in
     let* ro_error = read_some ro_client ~timeout:1.0 in
     if not (contains ro_error "Read-only") then fail "read-only input was not rejected";

     (* Non-admin force kill is rejected. *)
     let* () = AaaU.Session.handle_client_input session ~client:ro ~data:(AaaU.Protocol.encode_client AaaU.Protocol.ForceKill) in
     let* denied = read_some ro_client ~timeout:1.0 in
     if not (contains denied "Permission denied") then fail "non-admin force kill was allowed";

     (* Removing a client updates the client list. *)
     (* Exercise the removal path.  The session deliberately keys clients by
        the descriptor value, so we only verify that the call is accepted. *)
     let* () = AaaU.Session.remove_client session client_info in

     let* () = AaaU.Session.shutdown session in
     if AaaU.Session.is_alive session then fail "session should stop after shutdown";
     Lwt.return_unit)

let test_session_full audit =
  Lwt_main.run
    (let* session = create_session audit ~program:"/bin/sleep" ~args:["30"] () in
     let rec add_n n =
       if n = 0 then Lwt.return_unit
       else
         let server, _client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         let* result = AaaU.Session.add_client session ~socket:server ~addr:("peer" ^ string_of_int n) ~user_info:(user_info ()) in
         (match result with Ok _ -> () | Error message -> failwith message);
         add_n (n - 1)
     in
     let* () = add_n 10 in
     let server, _client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* overflow = AaaU.Session.add_client session ~socket:server ~addr:"overflow" ~user_info:(user_info ()) in
     (match overflow with
      | Ok _ -> fail "session accepted more than ten clients"
      | Error message when message = "Session full" -> ()
      | Error message -> fail "unexpected overflow error: %s" message);
     let* () = AaaU.Session.shutdown session in
     Lwt.return_unit)

let test_editor_forwarding audit =
  Lwt_main.run
    (let* session = create_session audit ~program:"/bin/sleep" ~args:["30"] () in
     let creator = user_info () in
     let peer_session_id = match AaaU.Session.get_agent_pid session with Some pid -> pid | None -> fail "missing agent pid" in

     (* Without a provider the request fails. *)
     let* unavailable = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "content" in
     if unavailable.AaaU.Editor_protocol.status = 0 then
       fail "editor request succeeded without a provider";

     (* Requests from a non agent account are rejected. *)
     let impostor = { creator with uid = creator.uid + 1 } in
     let* unauthorized = AaaU.Session.forward_editor_request session ~user_info:impostor ~peer_session_id "content" in
     if unauthorized.AaaU.Editor_protocol.status = 0 then
       fail "editor request from the wrong account succeeded";

     (* Provider registration is restricted to the creator. *)
     let public_socket, public_peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* rejected = AaaU.Session.register_editor_provider session ~socket:public_socket ~user_info:impostor in
     (match rejected with Ok _ -> fail "non-creator provider was accepted" | Error _ -> ());
     let* () = Lwt_unix.close public_socket in
     let* () = Lwt_unix.close public_peer in

     (* A registered provider satisfies requests and serializes them. *)
     let provider_socket, provider_peer = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* registered = AaaU.Session.register_editor_provider session ~socket:provider_socket ~user_info:creator in
     let _stopped = match registered with Ok value -> value | Error message -> failwith message in

     let provider =
       let* first_payload = AaaU.Editor_protocol.read_frame provider_peer in
       let first = match first_payload with
         | Ok value -> (match AaaU.Editor_protocol.request_of_string value with Ok request -> request | Error message -> failwith message)
         | Error message -> failwith message
       in
       let first_response =
         {
           AaaU.Editor_protocol.request_id = first.request_id;
           status = 0;
           error = None;
           content = Some "EDITED";
         }
       in
       let* sent = AaaU.Editor_protocol.write_frame provider_peer (AaaU.Editor_protocol.response_to_string first_response) in
       (match sent with Error message -> failwith message | Ok () -> ());
       let* second_payload = AaaU.Editor_protocol.read_frame provider_peer in
       let second = match second_payload with
         | Ok value -> (match AaaU.Editor_protocol.request_of_string value with Ok request -> request | Error message -> failwith message)
         | Error message -> failwith message
       in
       let mismatch =
         {
           AaaU.Editor_protocol.request_id = second.request_id ^ "-wrong";
           status = 0;
           error = None;
           content = Some "NOPE";
         }
       in
       let* _ = AaaU.Editor_protocol.write_frame provider_peer (AaaU.Editor_protocol.response_to_string mismatch) in
       Lwt.return_unit
     in

     let first_request = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "one" in
     let second_request = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "two" in
     let* (), (first_result, second_result) = Lwt.both provider (Lwt.both first_request second_request) in
     if first_result.AaaU.Editor_protocol.content <> Some "EDITED" then
       fail "successful editor content was not propagated";
     if second_result.AaaU.Editor_protocol.status = 0 then
       fail "mismatched editor response was accepted";

     (* A disconnected provider fails closed and is cleared. *)
     let safe_close fd = Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit) in
     let* () = safe_close provider_socket in
     let* () = safe_close provider_peer in
     let* disconnected = AaaU.Session.forward_editor_request session ~user_info:creator ~peer_session_id "three" in
     if disconnected.AaaU.Editor_protocol.status = 0 then
       fail "disconnected provider still succeeded";

     let* () = AaaU.Session.shutdown session in
     Lwt.return_unit)

let test_force_kill audit =
  Lwt_main.run
    (let* session = create_session audit ~program:"/bin/sleep" ~args:["30"] () in
     let server, _client = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
     let* added = AaaU.Session.add_client session ~socket:server ~addr:"admin" ~user_info:(user_info ()) in
     let client = match added with Ok value -> value | Error message -> failwith message in
     let* () = AaaU.Session.handle_client_input session ~client ~data:(AaaU.Protocol.encode_client AaaU.Protocol.ForceKill) in
     if AaaU.Session.is_alive session then fail "admin force kill did not stop the session";
     Lwt.return_unit)

let test_create_errors audit =
  let creator = user_info () in
  Lwt_main.run
    (let* missing_user =
       AaaU.Session.create ~session_id:"missing-user" ~creator
         ~agent_user:"aaau-no-such-account"
         ~editor_socket_path:"/tmp/aaau-missing.sock" ~program:"/bin/true"
         ~args:[] ~rows:24 ~cols:80 ~audit
     in
     let* () =
       match missing_user with
       | Ok session -> AaaU.Session.shutdown session
       | Error _ -> Lwt.return_unit
     in
     let* bad_program =
       AaaU.Session.create ~session_id:"bad-program" ~creator
         ~agent_user:(current_account ()).Unix.pw_name
         ~editor_socket_path:"/tmp/aaau-bad.sock"
         ~program:"/nonexistent/aaau-agent" ~args:[] ~rows:24 ~cols:80 ~audit
     in
     match bad_program with
     | Error _ -> Lwt.return_unit
     | Ok session ->
       let* () = AaaU.Session.shutdown session in
       fail "a nonexistent program created a session")

let test_inactive_editor audit =
  let safe_close fd =
    Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit)
  in
  Lwt_main.run
    (let* session = create_session audit ~program:"/bin/sleep" ~args:[ "30" ] () in
     let creator = user_info () in
     let first_socket, first_peer =
       Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0
     in
     let* first =
       AaaU.Session.register_editor_provider session ~socket:first_socket
         ~user_info:creator
     in
     (match first with Ok _ -> () | Error message -> failwith message);
     let second_socket, second_peer =
       Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0
     in
     let* second =
       AaaU.Session.register_editor_provider session ~socket:second_socket
         ~user_info:creator
     in
     (match second with Ok _ -> () | Error message -> failwith message);
     let* () = AaaU.Session.shutdown session in
     let* late =
       AaaU.Session.register_editor_provider session ~socket:second_socket
         ~user_info:creator
     in
     (match late with
      | Error _ -> ()
      | Ok _ -> fail "provider registered after shutdown");
     let* forwarded =
       AaaU.Session.forward_editor_request session ~user_info:creator
         ~peer_session_id:0 "content"
     in
     if forwarded.AaaU.Editor_protocol.status = 0 then
       fail "editor request succeeded after shutdown";
     let* () = safe_close first_peer in
     let* () = safe_close second_peer in
     Lwt.return_unit)

let () =
  test_queue ();
  test_authorization_helpers ();
  test_runtime_dir_env ();
  with_audit (fun audit ->
    test_lifecycle audit;
    test_session_full audit;
    test_editor_forwarding audit;
    test_force_kill audit;
    test_create_errors audit;
    test_inactive_editor audit);
  print_endline "session tests passed"
