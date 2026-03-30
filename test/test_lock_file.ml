(** Test lock file mechanism to prevent multiple instances *)

let lock_file_path = "/tmp/aaau_test.lock"

(* Simulate the lock file creation logic from server.ml *)
let create_lock_file path =
  try
    let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
    (* Write PID to lock file *)
    let pid = string_of_int (Unix.getpid ()) in
    Unix.write_substring fd pid 0 (String.length pid) |> ignore;
    Unix.close fd;
    Ok ()
  with
  | Unix.Unix_error (Unix.EEXIST, _, _) ->
    (* Lock file exists, check if process is still running *)
    begin
      try
        let ch = open_in path in
        let line = input_line ch in
        close_in ch;
        let old_pid = int_of_string line in
        (* Check if process is still running *)
        Unix.kill old_pid 0;
        Error (Printf.sprintf "Another instance is already running (PID %d)" old_pid)
      with
      | End_of_file
      | Failure _ ->
        (* Stale lock file, remove it *)
        Unix.unlink path;
        (* Retry creating lock *)
        let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
        let pid = string_of_int (Unix.getpid ()) in
        Unix.write_substring fd pid 0 (String.length pid) |> ignore;
        Unix.close fd;
        Ok ()
      | Unix.Unix_error (Unix.ESRCH, _, _) ->
        (* Process not running, stale lock *)
        Unix.unlink path;
        (* Retry creating lock *)
        let fd = Unix.openfile path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
        let pid = string_of_int (Unix.getpid ()) in
        Unix.write_substring fd pid 0 (String.length pid) |> ignore;
        Unix.close fd;
        Ok ()
    end
  | e ->
    Error (Printf.sprintf "Failed to create lock file: %s" (Printexc.to_string e))

let remove_lock_file path =
  try Unix.unlink path with _ -> ()

let test_lock_file_prevents_multiple_instances () =
  (* Clean up any existing lock file *)
  remove_lock_file lock_file_path;

  (* First instance should succeed *)
  let first_result = create_lock_file lock_file_path in
  match first_result with
  | Error e ->
    Printf.printf "FAIL: First instance failed: %s\n%!" e;
    remove_lock_file lock_file_path;
    false
  | Ok () ->
    (* Second instance should fail *)
    let second_result = create_lock_file lock_file_path in
    match second_result with
    | Error msg ->
      if String.starts_with ~prefix:"Another instance" msg then begin
        Printf.printf "PASS: Second instance correctly rejected: %s\n%!" msg;
        remove_lock_file lock_file_path;
        true
      end else begin
        Printf.printf "FAIL: Wrong error message: %s\n%!" msg;
        remove_lock_file lock_file_path;
        false
      end
    | Ok () ->
      Printf.printf "FAIL: Second instance should have been rejected\n%!";
      remove_lock_file lock_file_path;
      false

let test_lock_file_stale_lock () =
  (* Clean up any existing lock file *)
  remove_lock_file lock_file_path;

  (* Create a lock file with a non-existent PID *)
  let fd = Unix.openfile lock_file_path [Unix.O_CREAT; Unix.O_EXCL; Unix.O_WRONLY] 0o644 in
  Unix.write_substring fd "999999" 0 6 |> ignore;  (* Fake PID that doesn't exist *)
  Unix.close fd;

  (* Try to create lock - should succeed (stale lock detected) *)
  let result = create_lock_file lock_file_path in
  match result with
  | Ok () ->
    Printf.printf "PASS: Stale lock correctly detected and replaced\n%!";
    remove_lock_file lock_file_path;
    true
  | Error e ->
    Printf.printf "FAIL: Stale lock should have been replaced: %s\n%!" e;
    remove_lock_file lock_file_path;
    false

let test_lock_file_cleanup () =
  (* Clean up any existing lock file *)
  remove_lock_file lock_file_path;

  (* Create lock file *)
  let _ = create_lock_file lock_file_path in

  (* Verify lock file exists *)
  if not (Sys.file_exists lock_file_path) then begin
    Printf.printf "FAIL: Lock file was not created\n%!";
    false
  end else begin
    (* Clean up *)
    remove_lock_file lock_file_path;

    (* Verify lock file is removed *)
    if not (Sys.file_exists lock_file_path) then begin
      Printf.printf "PASS: Lock file cleanup works\n%!";
      true
    end else begin
      Printf.printf "FAIL: Lock file was not cleaned up\n%!";
      remove_lock_file lock_file_path;
      false
    end
  end

let () =
  Printf.printf "=== Test: Lock file mechanism ===\n%!";

  let results = [
    ("Multiple instances", test_lock_file_prevents_multiple_instances);
    ("Stale lock handling", test_lock_file_stale_lock);
    ("Lock file cleanup", test_lock_file_cleanup);
  ] in

  let passed = ref 0 in
  let failed = ref 0 in

  List.iter (fun (name, test_fn) ->
    Printf.printf "\n[%s] " name;
    if test_fn () then
      incr passed
    else
      incr failed
  ) results;

  Printf.printf "\n=== Results: %d passed, %d failed ===\n%!" !passed !failed;

  if !failed > 0 then
    exit 1
  else
    exit 0
