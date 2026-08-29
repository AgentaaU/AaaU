let fail message = prerr_endline message; exit 1
let expect condition message = if not condition then fail message

let write path content =
  let channel = open_out_bin path in output_string channel content; close_out channel

let read path =
  let channel = open_in_bin path in
  let length = in_channel_length channel in
  let value = really_input_string channel length in close_in channel; value

let () =
  let path = Filename.temp_file "aaau-source-" ".txt" in
  let moved = path ^ ".held" in
  let link = path ^ ".link" in
  write path "original";
  Unix.symlink path link;
  expect (Result.is_error (AaaU.Editor_buffer.open_source ~path:link ~owner_uid:(Unix.getuid ()))) "source symlink accepted";
  let source = match AaaU.Editor_buffer.open_source ~path ~owner_uid:(Unix.getuid ()) with
    | Ok source -> source | Error message -> fail message in
  begin match AaaU.Editor_buffer.read_source source with Ok "original" -> () | _ -> fail "source read failed" end;
  Unix.rename path moved;
  write path "attacker";
  let failed = { AaaU.Editor_protocol.request_id = "failed"; status = 7; error = Some "failed"; content = Some "must-not-copy" } in
  let failed_status, _ = AaaU.Editor_buffer.apply_response source failed in
  expect (failed_status = 7) "provider failure status changed";
  expect (read moved = "original") "failed edit modified the source";
  let successful = { AaaU.Editor_protocol.request_id = "ok"; status = 0; error = None; content = Some "edited" } in
  let success_status, _ = AaaU.Editor_buffer.apply_response source successful in
  expect (success_status = 0) "successful copy-back failed";
  AaaU.Editor_buffer.close_source source;
  expect (read moved = "edited") "held descriptor was not updated";
  expect (read path = "attacker") "replacement path was overwritten";

  let first = match AaaU.Editor_buffer.create_temporary ~content:"one" with Ok value -> value | Error message -> fail message in
  let second = match AaaU.Editor_buffer.create_temporary ~content:"two" with Ok value -> value | Error message -> fail message in
  let raced = match AaaU.Editor_buffer.create_temporary ~content:"race" with Ok value -> value | Error message -> fail message in
  let first_path = AaaU.Editor_buffer.temporary_path first in
  let second_path = AaaU.Editor_buffer.temporary_path second in
  expect (Filename.dirname first_path = "/tmp") "temporary is not under /tmp";
  expect (first_path <> second_path) "temporary names collided";
  expect ((Unix.stat first_path).Unix.st_perm land 0o777 = 0o600) "temporary mode is not 0600";
  let raced_path = AaaU.Editor_buffer.temporary_path raced in
  Unix.unlink raced_path;
  Unix.symlink moved raced_path;
  expect (Result.is_error (AaaU.Editor_buffer.read_temporary raced)) "replacement symlink was followed";
  AaaU.Editor_buffer.cleanup_temporary first;
  AaaU.Editor_buffer.cleanup_temporary second;
  AaaU.Editor_buffer.cleanup_temporary raced;
  expect (not (Sys.file_exists first_path) && not (Sys.file_exists second_path)) "temporary cleanup failed";
  let oversized = Filename.temp_file "aaau-oversized-" ".txt" in
  let oversized_fd = Unix.openfile oversized [Unix.O_RDWR] 0 in
  Unix.LargeFile.ftruncate oversized_fd (Int64.of_int (AaaU.Editor_protocol.max_buffer_size + 1));
  Unix.close oversized_fd;
  expect (Result.is_error (AaaU.Editor_buffer.open_source ~path:oversized ~owner_uid:(Unix.getuid ()))) "oversized source accepted";
  Unix.unlink oversized;
  List.iter (fun item -> try Unix.unlink item with _ -> ()) [path; moved; link];
  print_endline "editor buffer tests passed"
