open Lwt.Syntax

let fail message = prerr_endline message; exit 1
let expect condition message = if not condition then fail message
let write path content = let channel = open_out path in output_string channel content; close_out channel
let read path = let channel = open_in path in let value = input_line channel in close_in channel; value

let make_editor body =
  let path = Filename.temp_file "aaau-fake-editor-" ".sh" in
  write path ("#!/bin/sh\n" ^ body ^ "\n"); Unix.chmod path 0o700; path

let run_case ~body ~timeout expected_status expected_content =
  let tracker = Filename.temp_file "aaau-editor-track-" ".txt" in
  Unix.unlink tracker;
  let editor = make_editor body in
  let request = { AaaU.Editor_protocol.request_id = "test"; content = "before" } in
  let response = Lwt_main.run (AaaU.Editor_provider.handle_request ~timeout ~command:(editor, [tracker]) request) in
  expect (response.status = expected_status) "unexpected provider status";
  expect (response.content = expected_content) "unexpected provider content";
  let temporary_path = read tracker in
  expect (not (Sys.file_exists temporary_path)) "provider temporary was not cleaned";
  Unix.unlink tracker; Unix.unlink editor

let () =
  run_case ~body:"printf '%s\\n' \"$3\" > \"$1\"; test \"$2\" = -- || exit 9; printf edited > \"$3\"" ~timeout:2.0 0 (Some "edited");
  run_case ~body:"printf '%s\\n' \"$3\" > \"$1\"; exit 7" ~timeout:2.0 7 None;
  run_case ~body:"printf '%s\\n' \"$3\" > \"$1\"; sleep 10" ~timeout:0.05 124 None;
  let tracker = Filename.temp_file "aaau-editor-cancel-" ".txt" in
  Unix.unlink tracker;
  let editor = make_editor "printf '%s\\n' \"$3\" > \"$1\"; sleep 10" in
  let request = { AaaU.Editor_protocol.request_id = "cancel"; content = "before" } in
  let task = AaaU.Editor_provider.handle_request ~timeout:10.0 ~command:(editor, [tracker]) request in
  Lwt_main.run begin
    let rec wait_for_tracker attempts =
      if Sys.file_exists tracker then Lwt.return_unit
      else if attempts = 0 then Lwt.fail_with "fake editor did not start"
      else let* () = Lwt_unix.sleep 0.01 in wait_for_tracker (attempts - 1)
    in
    let* () = wait_for_tracker 100 in
    Lwt.cancel task;
    Lwt.catch (fun () -> let* _ = task in Lwt.return_unit) (fun _ -> Lwt.return_unit)
  end;
  let cancelled_path = read tracker in
  expect (not (Sys.file_exists cancelled_path)) "cancelled provider temporary was not cleaned";
  Unix.unlink tracker; Unix.unlink editor;
  print_endline "editor provider tests passed"
