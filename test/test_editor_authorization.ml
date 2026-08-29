let fail message = prerr_endline message; exit 1
let expect condition message = if not condition then fail message

let user uid username permission : AaaU.Auth.user_info = { username; uid; gid = uid; permission }

let () =
  let creator = user 2000 "creator" AaaU.Auth.Interactive in
  let other = user 2001 "other" AaaU.Auth.Interactive in
  let agent = user 900 "agent" AaaU.Auth.ReadOnly in
  expect (AaaU.Session.authorize_editor_provider ~creator_uid:2000 creator) "creator rejected";
  expect (not (AaaU.Session.authorize_editor_provider ~creator_uid:2000 other)) "non-creator provider accepted";
  expect (AaaU.Session.authorize_editor_request ~agent_uid:900 ~agent_session_id:4100 agent ~peer_session_id:4100) "agent rejected";
  expect (not (AaaU.Session.authorize_editor_request ~agent_uid:900 ~agent_session_id:4100 agent ~peer_session_id:4200)) "agent from another session accepted";
  expect (not (AaaU.Session.authorize_editor_request ~agent_uid:900 ~agent_session_id:4100 creator ~peer_session_id:4100)) "human request accepted";
  expect (AaaU.Auth.permission_for_uid 0 = AaaU.Auth.Admin) "root should be admin";
  expect (AaaU.Auth.permission_for_uid 1 = AaaU.Auth.Interactive) "non-root system UID became admin";
  expect (not (AaaU.Bridge.human_peer_allowed ~agent_uid:900 agent)) "agent allowed on control socket";
  expect (AaaU.Bridge.human_peer_allowed ~agent_uid:900 creator) "human denied on control socket";
  expect (AaaU.Bridge.human_socket_mode = 0o660) "human socket mode changed";
  expect (AaaU.Bridge.editor_socket_mode = 0o620) "editor socket is not agent-write-only";
  expect (AaaU.Bridge.groups_are_isolated ~agent_gid:10 ~human_gid:20 ~agent_username:"agent" ~human_members:[|"human"|]) "separate groups rejected";
  expect (not (AaaU.Bridge.groups_are_isolated ~agent_gid:10 ~human_gid:10 ~agent_username:"agent" ~human_members:[||])) "shared primary group accepted";
  expect (not (AaaU.Bridge.groups_are_isolated ~agent_gid:10 ~human_gid:20 ~agent_username:"agent" ~human_members:[|"agent"|])) "agent human-group membership accepted";
  begin match AaaU.Auth.authenticate ~peer_uid:0 ~peer_gid:0 ~shared_group:"root" with
  | Ok info -> expect (info.permission = AaaU.Auth.Admin) "root is not admin"
  | Error message -> fail message
  end;
  print_endline "editor authorization tests passed"
