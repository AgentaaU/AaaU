let fail fmt = Printf.ksprintf failwith fmt

let current_username () =
  (Unix.getpwuid (Unix.getuid ())).Unix.pw_name

let current_group_name () =
  (Unix.getgrgid (Unix.getgid ())).Unix.gr_name

let test_authenticate_socket_uses_peer_credentials () =
  let server_sock, client_sock = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close server_sock;
      Unix.close client_sock)
    (fun () ->
      match AaaU.Auth.authenticate_socket
              server_sock
              ~shared_group:(current_group_name ())
              ~admin_group:(current_group_name ())
      with
      | Error err -> fail "expected peer auth to succeed, got %s" err
      | Ok user_info ->
        if user_info.username <> current_username () then
          fail "expected username %s, got %s" (current_username ()) user_info.username;
        if user_info.uid <> Unix.getuid () then
          fail "expected uid %d, got %d" (Unix.getuid ()) user_info.uid;
        if user_info.gid <> Unix.getgid () then
          fail "expected gid %d, got %d" (Unix.getgid ()) user_info.gid;
        if user_info.permission <> AaaU.Auth.Admin then
          fail "expected explicit admin group membership to grant admin")

let test_authenticate_explicit_admin_group_required () =
  match AaaU.Auth.authenticate
          ~peer_uid:(Unix.getuid ())
          ~peer_gid:(Unix.getgid ())
          ~shared_group:(current_group_name ())
          ~admin_group:"group-that-should-not-exist-aaau"
  with
  | Error _ -> ()
  | Ok _ -> fail "expected authentication to fail for a nonexistent admin group"

let test_authenticate_non_admin_stays_interactive () =
  match AaaU.Auth.authenticate
          ~peer_uid:(Unix.getuid ())
          ~peer_gid:(Unix.getgid ())
          ~shared_group:(current_group_name ())
          ~admin_group:"root"
  with
  | Error _ -> ()
  | Ok user_info ->
    if user_info.permission <> AaaU.Auth.Interactive then
      fail "expected user outside admin group to stay interactive"

let test_authenticate_socket_rejects_wrong_group () =
  let server_sock, client_sock = Unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () ->
      Unix.close server_sock;
      Unix.close client_sock)
    (fun () ->
      match AaaU.Auth.authenticate_socket
              server_sock
              ~shared_group:"group-that-should-not-exist-aaau"
              ~admin_group:(current_group_name ())
      with
      | Error _ -> ()
      | Ok _ -> fail "expected authentication to fail for a nonexistent group")

let () =
  test_authenticate_socket_uses_peer_credentials ();
  test_authenticate_explicit_admin_group_required ();
  test_authenticate_non_admin_stays_interactive ();
  test_authenticate_socket_rejects_wrong_group ();
  print_endline "auth socket peer tests passed"
