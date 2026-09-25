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
      let mode = (Unix.stat log_path).Unix.st_perm in
      if mode <> 0o600 then
        fail "expected audit log mode 600, got %03o" mode;
      let content = In_channel.with_open_bin log_path In_channel.input_all in
      if not (String.contains content 'h') then
        fail "expected audit content to be written, got %S" content)

let test_audit_retention () =
  let tmp_dir = Filename.temp_file "aaau-audit-retention-" "" in
  Unix.unlink tmp_dir;
  Unix.mkdir tmp_dir 0o700;
  Fun.protect
    ~finally:(fun () ->
      Sys.readdir tmp_dir
      |> Array.iter (fun entry -> Unix.unlink (Filename.concat tmp_dir entry));
      Unix.rmdir tmp_dir)
    (fun () ->
      let today = Unix.localtime (Unix.time ()) in
      let date days_ago =
        let noon = { today with Unix.tm_mday = today.Unix.tm_mday - days_ago;
                                tm_hour = 12; tm_min = 0; tm_sec = 0 } in
        let day = Unix.localtime (fst (Unix.mktime noon)) in
        Printf.sprintf "%04d-%02d-%02d"
          (day.Unix.tm_year + 1900) (day.Unix.tm_mon + 1) day.Unix.tm_mday
      in
      let path days_ago =
        Filename.concat tmp_dir ("audit-" ^ date days_ago ^ ".logl") in
      let touch path = Out_channel.with_open_bin path (fun _ -> ()) in
      let old = path 5 and boundary = path 4 and current = path 0 in
      List.iter touch [old; boundary; current];
      let other = Filename.concat tmp_dir "notes.txt" in
      touch other;
      let symlink = Filename.concat tmp_dir ("audit-" ^ date 6 ^ ".logl") in
      Unix.symlink current symlink;
      let audit = Audit.create ~log_dir:tmp_dir in
      if Sys.file_exists old then fail "audit file older than five days remains";
      if not (Sys.file_exists boundary && Sys.file_exists current) then
        fail "audit file within five days was removed";
      if not (Sys.file_exists other && Sys.file_exists symlink) then
        fail "unrelated file or symlink was removed";
      Lwt_main.run (Audit.close audit))

let () =
  Printf.printf "=== Test: Audit log directory ===\n%!";
  test_audit_respects_configured_log_dir ();
  test_audit_retention ();
  Printf.printf "PASS\n%!"
