(* Cross-module coverage tests for paths not exercised by the focused suites.

   Each test targets a specific error or boundary branch that the regular
   suites do not reach, without requiring root. *)

open Lwt.Syntax

let fail fmt = Printf.ksprintf failwith fmt
let expect condition message = if not condition then failwith message
let run = Lwt_main.run

let with_dir f =
  let dir = Filename.temp_file "aaau-cov-" "" in
  Unix.unlink dir;
  Unix.mkdir dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      (try
         Sys.readdir dir
         |> Array.iter (fun entry ->
                try Unix.unlink (Filename.concat dir entry) with _ -> ())
       with _ -> ());
      (try Unix.rmdir dir with _ -> ()))
    (fun () -> f dir)

let write_file path content =
  let channel = open_out_bin path in
  output_string channel content;
  close_out channel

(* ------------------------------------------------------------------ *)
(* Command line                                                        *)
(* ------------------------------------------------------------------ *)

let test_command_line () =
  (match AaaU.Command_line.split_command "\"abc\\" with
  | Error _ -> ()
  | Ok _ -> fail "trailing backslash in double quotes was accepted");
  (match AaaU.Command_line.split_command "'a\\b'" with
  | Ok ("a\\b", []) -> ()
  | _ -> fail "backslash inside single quotes was mishandled");
  List.iter
    (fun alias ->
      match AaaU.Command_line.expand_program_alias alias with
      | Some _ -> ()
      | None -> fail "known alias %s was not expanded" alias)
    [ "codex"; "claude"; "opencode"; "pi" ];
  (match AaaU.Command_line.expand_program_alias "not-an-alias" with
  | None -> ()
  | Some _ -> fail "unknown alias was expanded")

(* ------------------------------------------------------------------ *)
(* Client IO                                                           *)
(* ------------------------------------------------------------------ *)

let test_client_io_default_timeout () =
  let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  run
    (let* () = AaaU.Client_io.write_all right "line\nrest" in
     let* result = AaaU.Client_io.read_handshake_response left in
     (match result with
      | AaaU.Client_io.Response ("line", "rest") -> ()
      | _ -> fail "default-timeout handshake response mismatch");
     Lwt_unix.close left)

(* ------------------------------------------------------------------ *)
(* Editor protocol                                                     *)
(* ------------------------------------------------------------------ *)

let test_editor_protocol () =
  (match
     AaaU.Editor_protocol.request_of_string
       "{\"request_id\":\"id\",\"content_hex\":\"AB\"}"
   with
  | Ok request -> expect (request.AaaU.Editor_protocol.content = "\xab")
                    "uppercase hex was decoded incorrectly"
  | Error message -> fail "uppercase hex was rejected: %s" message);
  expect
    (Result.is_error
       (AaaU.Editor_protocol.response_of_string
          "{\"request_id\":\"id\",\"status\":0,\"content_hex\":123}"))
    "non-string content_hex was accepted";
  let left, right = Lwt_unix.socketpair Unix.PF_UNIX Unix.SOCK_STREAM 0 in
  run
    (let* result =
       AaaU.Editor_protocol.write_frame left
         (String.make (AaaU.Editor_protocol.max_payload + 1) 'x')
     in
     (match result with Error _ -> () | Ok _ -> fail "oversized write_frame succeeded");
     let* () = Lwt_unix.close right in
     let* () = Lwt_unix.close left in
     let* closed = AaaU.Editor_protocol.write_frame left "data" in
     (match closed with
      | Error _ -> ()
      | Ok _ -> fail "write_frame on a closed descriptor succeeded");
     Lwt.return_unit)

(* ------------------------------------------------------------------ *)
(* Authentication                                                      *)
(* ------------------------------------------------------------------ *)

let test_auth_paths () =
  let uid = Unix.getuid () in
  let gid = Unix.getgid () in
  let primary_group = (Unix.getgrgid gid).Unix.gr_name in
  (* The peer gid deliberately differs from the group gid so that the
     membership check has to inspect the account's primary group. *)
  (match AaaU.Auth.authenticate ~peer_uid:uid ~peer_gid:(-1) ~shared_group:primary_group with
  | Ok _ -> ()
  | Error message -> fail "primary-group authentication failed: %s" message);
  (* A non-socket descriptor makes the credential lookup fail. *)
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () -> Unix.close read_fd; Unix.close write_fd)
    (fun () ->
      (match AaaU.Auth.authenticate_socket read_fd ~shared_group:primary_group with
      | Error _ -> ()
      | Ok _ -> fail "authenticate_socket accepted a pipe");
      (match AaaU.Auth.authenticate_agent_socket read_fd ~agent_user:"root" with
      | Error _ -> ()
      | Ok _ -> fail "authenticate_agent_socket accepted a pipe"))

(* ------------------------------------------------------------------ *)
(* Audit                                                               *)
(* ------------------------------------------------------------------ *)

let test_audit_filenames () =
  with_dir (fun dir ->
      let names =
        [
          "audit-2020-01-01.logl";
          "audit-2020-1-01.logl";
          "audit-2020-13-01.logl";
          "audit-2020-00-01.logl";
          "audit-2020-12-00.logl";
          "audit-2020-12-32.logl";
          "audit-2020-12-01.log";
          "audit-2020-12-01xlogl";
          "audit_2020-12-01.logl";
          "audit-20a0-12-01.logl";
          "audit-2020x12-01.logl";
          "audit-2020-12x01.logl";
          "notes.txt";
        ]
      in
      List.iter (fun name -> write_file (Filename.concat dir name) "") names;
      let audit = AaaU.Audit.create ~log_dir:dir in
      run (AaaU.Audit.close audit))

let test_audit_flush_loop () =
  with_dir (fun dir ->
      let audit = AaaU.Audit.create ~log_dir:dir in
      let record =
        {
          AaaU.Audit.timestamp = Unix.time ();
          source = "system";
          user = "tester";
          session_id = "session";
          command_type = "control";
          content = "tick";
          metadata = [];
        }
      in
      run (AaaU.Audit.log audit record);
      (* Drive the periodic flush loop past its five second tick. *)
      run (Lwt_unix.sleep 5.5);
      run (AaaU.Audit.close audit))

let test_audit_flush_error () =
  with_dir (fun dir ->
      let audit = AaaU.Audit.create ~log_dir:dir in
      let record =
        {
          AaaU.Audit.timestamp = Unix.time ();
          source = "system";
          user = "tester";
          session_id = "session";
          command_type = "control";
          content = "tick";
          metadata = [];
        }
      in
      run (AaaU.Audit.log audit record);
      (* Make the directory unwritable so the periodic flush fails and logs. *)
      Unix.chmod dir 0o500;
      run (Lwt_unix.sleep 5.5);
      Unix.chmod dir 0o700;
      run (AaaU.Audit.close audit))

(* ------------------------------------------------------------------ *)
(* Editor buffer                                                       *)
(* ------------------------------------------------------------------ *)

let test_editor_buffer_paths () =
  with_dir (fun dir ->
      (* A FIFO is opened successfully but is not a regular buffer file. *)
      let fifo = Filename.concat dir "fifo" in
      Unix.mkfifo fifo 0o600;
      (match AaaU.Editor_buffer.open_source ~path:fifo ~owner_uid:(Unix.getuid ()) with
      | Error _ -> ()
      | Ok source ->
        AaaU.Editor_buffer.close_source source;
        fail "FIFO was accepted as an editor buffer");
      let path = Filename.concat dir "buffer.txt" in
      write_file path "original";
      let uid = Unix.getuid () in
      (match AaaU.Editor_buffer.open_source ~path ~owner_uid:uid with
      | Error message -> fail "open_source failed: %s" message
      | Ok source ->
        (* A non-zero provider status is reported without touching the file. *)
        let rejected =
          {
            AaaU.Editor_protocol.request_id = "r";
            status = 5;
            error = Some "refused";
            content = Some "ignored";
          }
        in
        let status, message = AaaU.Editor_buffer.apply_response source rejected in
        expect (status = 5) "non-zero status was not preserved";
        expect (message = Some "refused") "non-zero error was not preserved";
        expect
          (match AaaU.Editor_buffer.read_source source with
           | Ok "original" -> true
           | _ -> false)
          "rejected response modified the buffer";
        (* Growing the file past the limit after open makes the rollback read
           fail with the size-limit error. *)
        let channel = open_out_gen [ Open_append; Open_binary ] 0o600 path in
        output_string channel (String.make (AaaU.Editor_protocol.max_buffer_size + 1) 'x');
        close_out channel;
        (match AaaU.Editor_buffer.write_source source "new" with
        | Error _ -> ()
        | Ok () -> fail "oversized source write succeeded");
        AaaU.Editor_buffer.close_source source);
      (* Tampering with the temporary file is detected. *)
      (match AaaU.Editor_buffer.create_temporary ~content:"secret" with
      | Error message -> fail "create_temporary failed: %s" message
      | Ok temporary ->
        let temp_path = AaaU.Editor_buffer.temporary_path temporary in
        Unix.chmod temp_path 0o666;
        (match AaaU.Editor_buffer.read_temporary temporary with
        | Error _ -> ()
        | Ok _ -> fail "read_temporary accepted weakened permissions");
        AaaU.Editor_buffer.cleanup_temporary temporary);
      (* Cleaning up a temporary replaced by a directory exercises the
         best-effort unlink error path. *)
      (match AaaU.Editor_buffer.create_temporary ~content:"x" with
      | Error message -> fail "create_temporary failed: %s" message
      | Ok temporary ->
        let temp_path = AaaU.Editor_buffer.temporary_path temporary in
        Unix.unlink temp_path;
        Unix.mkdir temp_path 0o700;
        AaaU.Editor_buffer.cleanup_temporary temporary;
        (try Unix.rmdir temp_path with _ -> ())))

(* ------------------------------------------------------------------ *)
(* Editor provider                                                     *)
(* ------------------------------------------------------------------ *)

let make_script body =
  let path = Filename.temp_file "aaau-cov-editor-" ".sh" in
  write_file path ("#!/bin/sh\n" ^ body ^ "\n");
  Unix.chmod path 0o700;
  path

let provider_case ?timeout ~body ~expected_status request =
  let editor = make_script body in
  let response =
    run
      (match timeout with
       | Some timeout ->
         AaaU.Editor_provider.handle_request ~timeout ~command:(editor, []) request
       | None -> AaaU.Editor_provider.handle_request ~command:(editor, []) request)
  in
  expect (response.AaaU.Editor_protocol.status = expected_status)
    (Printf.sprintf "unexpected provider status %d (expected %d)"
       response.AaaU.Editor_protocol.status expected_status);
  Unix.unlink editor

let test_editor_provider_paths () =
  let request = { AaaU.Editor_protocol.request_id = "r"; content = "before" } in
  (* Oversized content fails before starting a process. *)
  let oversized =
    {
      AaaU.Editor_protocol.request_id = "r";
      content = String.make (AaaU.Editor_protocol.max_buffer_size + 1) 'z';
    }
  in
  let response =
    run
      (AaaU.Editor_provider.handle_request ~timeout:1.0
         ~command:("/bin/true", []) oversized)
  in
  expect (response.AaaU.Editor_protocol.status = 74)
    "oversized provider content did not fail";
  (* The default timeout path runs without an explicit timeout. *)
  provider_case ~body:"exit 0" ~expected_status:0 request;
  (* A process killed by a signal reports 128+signal. *)
  provider_case ~body:"kill -TERM $$"
    ~expected_status:(128 + Sys.sigterm) request;
  (* Tampering with the temporary file is detected after a clean exit. *)
  let chmod = make_script "chmod 0777 \"$2\"" in
  let response =
    run
      (AaaU.Editor_provider.handle_request ~timeout:2.0
         ~command:(chmod, []) request)
  in
  expect (response.AaaU.Editor_protocol.status = 74)
    "provider did not detect a permission change";
  Unix.unlink chmod

(* ------------------------------------------------------------------ *)
(* PTY helpers                                                         *)
(* ------------------------------------------------------------------ *)

let test_pty_paths () =
  (* Setting a terminal size on a non-terminal is a silent no-op. *)
  let read_fd, write_fd = Unix.pipe () in
  Fun.protect
    ~finally:(fun () -> Unix.close read_fd; Unix.close write_fd)
    (fun () ->
      AaaU.Pty.set_terminal_size read_fd ~rows:10 ~cols:10;
      AaaU.Pty.set_controlling_terminal read_fd;
      let rows, cols = AaaU.Pty.get_terminal_size read_fd in
      expect (rows = 24 && cols = 80) "non-terminal size fallback changed")

let () =
  test_command_line ();
  test_client_io_default_timeout ();
  test_editor_protocol ();
  test_auth_paths ();
  test_audit_filenames ();
  test_audit_flush_loop ();
  test_audit_flush_error ();
  test_editor_buffer_paths ();
  test_editor_provider_paths ();
  test_pty_paths ();
  print_endline "coverage extension tests passed"
