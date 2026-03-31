(** Regression test for output history compaction.
    Large PTY output must not permanently stall later broadcasts. *)

open AaaU

let test_output_buffer_compaction () =
  let buffer = Buffer.create 102400 in
  let first = String.make 80000 'a' in
  let second = String.make 40000 'b' in
  Buffer.add_string buffer first;
  let last_sent_pos = Buffer.length buffer in
  Buffer.add_string buffer second;

  let adjusted = Session.compact_output_buffer buffer ~last_sent_pos in
  let contents = Buffer.contents buffer in

  if Buffer.length buffer <> 60000 then begin
    Printf.printf "FAIL: expected compacted length 60000, got %d\n%!" (Buffer.length buffer);
    false
  end else if adjusted <> 20000 then begin
    Printf.printf "FAIL: expected adjusted last_sent_pos 20000, got %d\n%!" adjusted;
    false
  end else if not (String.for_all (fun c -> c = 'a') (String.sub contents 0 20000)) then begin
    Printf.printf "FAIL: expected retained unsent prefix from original buffer\n%!";
    false
  end else if not (String.ends_with ~suffix:(String.make 40000 'b') contents) then begin
    Printf.printf "FAIL: expected new output to remain in compacted buffer\n%!";
    false
  end else begin
    Printf.printf "PASS: output buffer compaction preserves pending output\n%!";
    true
  end

let () =
  Printf.printf "=== Test: Output buffer compaction ===\n%!";
  let result = test_output_buffer_compaction () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
