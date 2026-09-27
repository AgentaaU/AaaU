(* Coverage-oriented tests for authentication and permissions. *)

open AaaU

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message

let current_group_name () = (Unix.getgrgid (Unix.getgid ())).Unix.gr_name

let test_permission_helpers () =
  expect (Auth.string_of_permission Auth.ReadOnly = "readonly") "readonly string";
  expect (Auth.string_of_permission Auth.Interactive = "interactive") "interactive string";
  expect (Auth.string_of_permission Auth.Admin = "admin") "admin string";
  expect (Auth.permission_of_string "readonly" = Some Auth.ReadOnly) "readonly parse";
  expect (Auth.permission_of_string "interactive" = Some Auth.Interactive) "interactive parse";
  expect (Auth.permission_of_string "admin" = Some Auth.Admin) "admin parse";
  expect (Auth.permission_of_string "nope" = None) "unknown permission parsed";
  expect (Auth.permission_for_uid 0 = Auth.Admin) "root is not admin";
  expect (Auth.permission_for_uid 1000 = Auth.Interactive) "non-root is not interactive"

let test_check_permission () =
  expect (Auth.check_permission Auth.Admin ~action:"anything") "admin denied";
  expect (Auth.check_permission Auth.Interactive ~action:"input") "interactive input denied";
  expect (Auth.check_permission Auth.Interactive ~action:"resize") "interactive resize denied";
  expect (Auth.check_permission Auth.Interactive ~action:"ping") "interactive ping denied";
  expect (not (Auth.check_permission Auth.Interactive ~action:"kill")) "interactive kill allowed";
  expect (Auth.check_permission Auth.ReadOnly ~action:"read") "readonly read denied";
  expect (not (Auth.check_permission Auth.ReadOnly ~action:"input")) "readonly input allowed"

let test_authenticate () =
  (match Auth.authenticate ~peer_uid:0 ~peer_gid:0 ~shared_group:"root" with
  | Ok info ->
    expect (info.Auth.permission = Auth.Admin) "root did not receive admin"
  | Error message -> fail "root authentication failed: %s" message);

  let uid = Unix.getuid () and gid = Unix.getgid () in
  (match Auth.authenticate ~peer_uid:uid ~peer_gid:gid ~shared_group:(current_group_name ()) with
  | Ok info ->
    expect (info.Auth.uid = uid) "authenticated uid mismatch";
    if uid <> 0 then
      expect (info.Auth.permission = Auth.Interactive) "non-root was not interactive"
  | Error message -> fail "current user authentication failed: %s" message);

  (match Auth.authenticate ~peer_uid:uid ~peer_gid:gid ~shared_group:"group-that-does-not-exist" with
  | Error _ -> ()
  | Ok _ -> fail "authentication succeeded with a nonexistent group");

  if uid <> 0 then
    match Auth.authenticate ~peer_uid:uid ~peer_gid:gid ~shared_group:"daemon" with
    | Error message ->
      expect
        (String.starts_with ~prefix:"User " message)
        (Printf.sprintf "unexpected group rejection message: %s" message)
    | Ok _ -> fail "authentication succeeded without group membership"

let with_socketpair f =
  let left, right = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect ~finally:(fun () -> Unix.close left; Unix.close right) (fun () -> f left)

let test_agent_socket () =
  let account = Unix.getpwuid (Unix.getuid ()) in
  with_socketpair (fun server ->
    match Auth.authenticate_agent_socket server ~agent_user:account.Unix.pw_name with
    | Ok (info, session_id) ->
      expect (info.Auth.uid = account.Unix.pw_uid) "agent uid mismatch";
      expect (info.Auth.permission = Auth.ReadOnly) "agent permission should be read-only";
      expect (session_id > 0) "peer session id should be positive"
    | Error message -> fail "agent socket authentication failed: %s" message);

  with_socketpair (fun server ->
    match Auth.authenticate_agent_socket server ~agent_user:"daemon" with
    | Error _ -> ()
    | Ok _ -> fail "non-agent account was accepted on the editor socket");

  with_socketpair (fun server ->
    match Auth.authenticate_agent_socket server ~agent_user:"aaau-no-such-account" with
    | Error message ->
      expect
        (String.starts_with ~prefix:"Configured agent" message)
        (Printf.sprintf "unexpected missing-account message: %s" message)
    | Ok _ -> fail "missing agent account was accepted")

let () =
  test_permission_helpers ();
  test_check_permission ();
  test_authenticate ();
  test_agent_socket ();
  print_endline "auth tests passed"
