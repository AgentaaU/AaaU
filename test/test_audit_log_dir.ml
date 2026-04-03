open AaaU

let fail fmt = Printf.ksprintf failwith fmt

let test_audit_respects_configured_log_dir () =
  let tmp_dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "aaau-audit-%d" (Unix.getpid ()))
  in
  if Sys.file_exists tmp_dir then
    fail "temporary directory already exists: %s" tmp_dir;
  Unix.mkdir tmp_dir 0o755;
  Fun.protect
    ~finally:(fun () ->
      if Sys.file_exists tmp_dir then begin
        Sys.readdir tmp_dir
        |> Array.iter (fun entry -> Unix.unlink (Filename.concat tmp_dir entry));
        Unix.rmdir tmp_dir
      end)
    (fun () ->
      let audit = Audit.create ~log_dir:tmp_dir in
      let record = {
        Audit.timestamp = Unix.time ();
        source = "system";
        user = "test";
        session_id = "session";
        command_type = "session_start";
        content = "hello";
        metadata = [];
      } in
      Lwt_main.run (Audit.log audit record);
      Lwt_main.run (Audit.flush audit);
      let files = Sys.readdir tmp_dir in
      if Array.length files <> 1 then
        fail "expected exactly one audit log file, found %d" (Array.length files);
      let log_path = Filename.concat tmp_dir files.(0) in
      let content = In_channel.with_open_bin log_path In_channel.input_all in
      if not (String.contains content 'h') then
        fail "expected audit content to be written, got %S" content)

let () =
  Printf.printf "=== Test: Audit log directory ===\n%!";
  test_audit_respects_configured_log_dir ();
  Printf.printf "PASS\n%!"
