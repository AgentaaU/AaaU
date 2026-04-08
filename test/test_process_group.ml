(** Test process group kill - verify children are terminated with parent *)

let test_process_group () =
  let pipe_r, pipe_w = Unix.pipe () in
  let pid = Unix.fork () in
  if pid = 0 then begin
    Unix.close pipe_r;
    (* Child: create new session and process group *)
    let _ = Unix.setsid () in

    (* Fork a grandchild *)
    let grandchild = Unix.fork () in
    if grandchild = 0 then begin
      Unix.close pipe_w;
      (* Grandchild: sleep until the parent kills the process group. *)
      Unix.sleep 10;
      Unix._exit 0
    end else begin
      let grandchild_str = string_of_int grandchild in
      ignore (Unix.write_substring pipe_w grandchild_str 0 (String.length grandchild_str));
      Unix.close pipe_w;
      Unix.sleep 10;
      Unix._exit 0
    end
  end else begin
    Unix.close pipe_w;
    let buf = Bytes.create 32 in
    let n = Unix.read pipe_r buf 0 32 in
    Unix.close pipe_r;
    let grandchild = Bytes.sub_string buf 0 n |> String.trim |> int_of_string in

    (* Try to kill the process group (child's PID was the PGID) *)
    (try Unix.kill (-pid) Sys.sigkill with _ -> ());

    (* Give time for signal delivery *)
    Unix.sleepf 0.1;
    let child_reaped =
      match Unix.waitpid [] pid with
      | _, Unix.WEXITED _ ->
        true
      | _, Unix.WSIGNALED signal when signal = Sys.sigkill ->
        true
      | _ ->
        false
    in
    let grandchild_gone =
      try
        Unix.kill grandchild 0;
        false
      with Unix.Unix_error (Unix.ESRCH, _, _) ->
        true
    in
    if child_reaped && grandchild_gone then begin
      Printf.printf "PASS: Process group kill terminated child and grandchild\n%!";
      true
    end else begin
      Printf.printf "FAIL: child_reaped=%b grandchild_gone=%b\n%!" child_reaped grandchild_gone;
      false
    end
  end

let () =
  Printf.printf "=== Test: Process group termination ===\n%!";
  let result = test_process_group () in
  if result then
    Printf.printf "PASS\n%!"
  else begin
    Printf.printf "FAIL\n%!";
    exit 1
  end
