(** Tests for per-session agent user selection ([aaau --user]).

    [NEW_JSON] carries an optional [user] field that selects which isolated
    agent account runs the session.  These tests exercise the parser/validator
    and the server-side defaulting without needing root: the real account switch
    happens inside [Session.create] and is covered by the privileged suite. *)

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

let current_account () = Unix.getpwuid (Unix.getuid ())

let account_exists name =
  try
    let _ = Unix.getpwnam name in
    true
  with Not_found -> false

let requestable_user () =
  let current = current_account () in
  let candidates = [ "daemon"; "nobody"; "bin" ] in
  let rec pick = function
    | [] -> fail "no non-root account available for tests"
    | name :: rest ->
      begin
        try
          let account = Unix.getpwnam name in
          if account.Unix.pw_uid <> 0 && account.Unix.pw_uid <> current.Unix.pw_uid
          then name
          else pick rest
        with Not_found -> pick rest
      end
  in
  pick candidates

let primary_group_name name =
  (Unix.getgrgid (Unix.getpwnam name).Unix.pw_gid).Unix.gr_name

(* "root" is a portable group whose gid (0) differs from every requestable
   account's primary gid and whose membership does not include the test
   account, so it exercises the isolation invariant. *)
let isolated_shared_group () =
  if account_exists "root" then "root" else "daemon"

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

let with_bridge ?(shared_group = isolated_shared_group ()) agent_user f =
  let dir = Filename.temp_file "aaau-bridge-user-test-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  let log_dir = Filename.concat dir "logs" in
  let bridge =
    AaaU.Bridge.create
      ~socket_path:(Filename.concat dir "server.sock")
      ~shared_group ~agent_user ~log_dir
      ~default_program:"/bin/echo" ~default_args:["-n"; "default"] ()
  in
  Fun.protect
    ~finally:(fun () ->
      Lwt_main.run (AaaU.Bridge.stop bridge);
      remove_tree dir)
    (fun () -> f bridge)

let test_new_json_defaults () =
  let agent = (current_account ()).Unix.pw_name in
  with_bridge agent (fun bridge ->
    let explicit =
      "{\"program\":\"/bin/true\",\"args\":[],\"rows\":24,\"cols\":80}"
    in
    expect
      (AaaU.Bridge.new_json_defaults bridge explicit = explicit)
      "payload with an explicit program should not be rewritten";
    let only_args = "{\"args\":[],\"rows\":24,\"cols\":80}" in
    expect
      (AaaU.Bridge.new_json_defaults bridge only_args = only_args)
      "payload with args but no program should not be rewritten";
    let no_program = "{\"user\":\"agent\",\"rows\":24,\"cols\":80}" in
    match
      AaaU.Bridge.parse_new_json
        (AaaU.Bridge.new_json_defaults bridge no_program)
    with
    | Ok ("/bin/echo", [ "-n"; "default" ], 24, 80) -> ()
    | _ -> fail "server default program and args were not applied")

let test_requested_agent_user () =
  let current = current_account () in
  let requestable = requestable_user () in
  with_bridge current.Unix.pw_name (fun bridge ->
    (* Missing field falls back to the configured agent user. *)
    (match AaaU.Bridge.requested_agent_user bridge "{\"rows\":24,\"cols\":80}" with
     | Ok name -> expect (name = current.Unix.pw_name) "default agent user mismatch"
     | Error e -> fail "default agent user rejected: %s" e);
    (* Selecting the account we already run as is always allowed (root excepted
       because root may never be an agent). *)
    if current.Unix.pw_uid <> 0 then
      (match
         AaaU.Bridge.requested_agent_user bridge
           (Printf.sprintf "{\"user\":%S}" current.Unix.pw_name)
       with
       | Ok name -> expect (name = current.Unix.pw_name) "explicit current user mismatch"
       | Error e -> fail "explicit current user rejected: %s" e);
    (* Empty and non-string values are rejected. *)
    (match AaaU.Bridge.requested_agent_user bridge "{\"user\":\"\"}" with
     | Error e -> expect (contains e "user") ("unexpected empty-user error: " ^ e)
     | Ok _ -> fail "empty user accepted");
    (match AaaU.Bridge.requested_agent_user bridge "{\"user\":123}" with
     | Error e -> expect (contains e "user") ("unexpected non-string-user error: " ^ e)
     | Ok _ -> fail "non-string user accepted");
    (match AaaU.Bridge.requested_agent_user bridge "{\"user\":\"aaau-no-such-account\"}" with
     | Error e -> expect (contains e "not found") ("unexpected missing-account error: " ^ e)
     | Ok _ -> fail "missing account accepted");
    (* The agent must not be root. *)
    (match AaaU.Bridge.requested_agent_user bridge "{\"user\":\"root\"}" with
     | Error e -> expect (contains e "root") ("unexpected root error: " ^ e)
     | Ok _ -> fail "root accepted as agent");
    (* A non-object payload is rejected. *)
    (match AaaU.Bridge.requested_agent_user bridge "[]" with
     | Error _ -> ()
     | Ok _ -> fail "array payload accepted");
    (* Selecting a different account requires a root-run server. *)
    match
      AaaU.Bridge.requested_agent_user bridge
        (Printf.sprintf "{\"user\":%S}" requestable)
    with
    | Ok name when current.Unix.pw_uid = 0 ->
      expect (name = requestable) "root server picked the wrong account"
    | Ok _ -> fail "non-root server selected another account"
    | Error e when current.Unix.pw_uid = 0 ->
      fail "root server rejected %s: %s" requestable e
    | Error e ->
      expect (contains e "root")
        (Printf.sprintf "unexpected other-account error: %s" e))

let test_requested_agent_user_rejects_shared_group () =
  let current = current_account () in
  let requestable = requestable_user () in
  (* Put the requested account's own primary group in the human control group:
     isolation must be refused even for an otherwise valid account. *)
  let shared_group = primary_group_name requestable in
  with_bridge ~shared_group current.Unix.pw_name (fun bridge ->
    match
      AaaU.Bridge.requested_agent_user bridge
        (Printf.sprintf "{\"user\":%S}" requestable)
    with
    | Error e -> expect (contains e "human") ("unexpected shared-group error: " ^ e)
    | Ok _ -> fail "account in the human control group was accepted")

let read_line fd =
  let* result = AaaU.Client_io.read_line_with_remainder ~timeout:0.5 fd in
  match result with
  | AaaU.Client_io.Line (line, _) -> Lwt.return (Some line)
  | AaaU.Client_io.End_of_file -> Lwt.return (Some "")
  | AaaU.Client_io.Timeout_line -> Lwt.return None

(* Drive a full handshake that names the agent account explicitly.  This needs
   no privilege transition because the requested account is the one the test
   process already runs as. *)
let test_handshake_explicit_user () =
  let current = current_account () in
  if current.Unix.pw_uid = 0 then ()
  else
    with_bridge current.Unix.pw_name (fun bridge ->
      Lwt_main.run
        (let server_fd, peer_fd = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
         let request =
           Printf.sprintf
             "NEW_JSON:{\"program\":\"/bin/true\",\"args\":[],\"user\":%S,\"rows\":24,\"cols\":80}\n"
             current.Unix.pw_name
         in
         let* () = AaaU.Client_io.write_all peer_fd request in
         let* result = AaaU.Bridge.handle_handshake bridge server_fd
             { AaaU.Auth.username = current.Unix.pw_name;
               uid = current.Unix.pw_uid;
               gid = current.Unix.pw_gid;
               permission = AaaU.Auth.Admin } in
         (match result with
          | Ok (`New (session, _)) ->
            expect
              (AaaU.Session.get_id session <> "")
              "session created for explicit user has no id"
          | Ok _ -> fail "explicit-user handshake did not create a session"
          | Error e -> fail "explicit-user handshake failed: %s" e);
         let* response = read_line peer_fd in
         (match response with
          | Some line ->
            expect
              (String.starts_with ~prefix:"SESSION:" line)
              (Printf.sprintf "unexpected handshake response: %S" line)
          | None -> fail "explicit-user handshake produced no response");
         let* () = Lwt.catch (fun () -> Lwt_unix.close peer_fd) (fun _ -> Lwt.return_unit) in
         Lwt.catch (fun () -> Lwt_unix.close server_fd) (fun _ -> Lwt.return_unit)))

let run_tests () =
  test_new_json_defaults ();
  test_requested_agent_user ();
  test_requested_agent_user_rejects_shared_group ();
  test_handshake_explicit_user ();
  print_endline "bridge user tests passed"


let () =
  run_tests ();
  (* Forgejo runs the coverage suite as root. Also exercise the unprivileged
     server path: it must accept its own account and refuse switching to a
     different UID. A normal exit flushes the child's Bisect counters. *)
  if Unix.geteuid () = 0 then begin
    let account = Unix.getpwnam (requestable_user ()) in
    (* The build tree is root-owned in CI. Give the child a writable counter
       directory, then collect its coverage files before removing it. *)
    let counters = Filename.temp_file "aaau-user-counters-" "" in
    Unix.unlink counters;
    Unix.mkdir counters 0o700;
    Unix.chown counters account.Unix.pw_uid account.Unix.pw_gid;
    Fun.protect ~finally:(fun () -> remove_tree counters) (fun () ->
    match Unix.fork () with
    | 0 ->
      Unix.putenv "BISECT_FILE" (Filename.concat counters "bisect");
      Unix.setgroups [||];
      Unix.setgid account.Unix.pw_gid;
      Unix.setuid account.Unix.pw_uid;
      run_tests ();
      exit 0
    | pid ->
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED 0 ->
        Array.iter (fun name ->
          if Filename.check_suffix name ".coverage" then begin
            let input = open_in_bin (Filename.concat counters name) in
            let data = really_input_string input (in_channel_length input) in
            close_in input;
            let output = open_out_bin ("unprivileged-" ^ name) in
            output_string output data;
            close_out output
          end) (Sys.readdir counters)
      | _ -> fail "unprivileged agent-user tests failed")
  end
