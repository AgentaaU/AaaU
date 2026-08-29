open Lwt.Syntax

let response request_id status error content =
  { Editor_protocol.request_id; status; error; content }

let handle_request ?(timeout=Editor_protocol.request_timeout_seconds -. 5.0) ~command (request : Editor_protocol.request) =
  match Editor_buffer.create_temporary ~content:request.Editor_protocol.content with
  | Error message -> Lwt.return (response request.request_id 74 (Some message) None)
  | Ok temporary ->
    Lwt.finalize
      (fun () ->
        let program, base_args = command in
        let path = Editor_buffer.temporary_path temporary in
        (* emacsclient waits by default; it has --no-wait but no --wait flag. *)
        let argv = Array.of_list (program :: base_args @ ["--"; path]) in
        Lwt.catch
          (fun () ->
            let process = Lwt_process.open_process_none
              ~stdin:`Dev_null ~stdout:`Dev_null ~stderr:`Dev_null (program, argv) in
            Lwt.finalize
              (fun () ->
                let finished = let* status = process#status in Lwt.return (`Finished status) in
                let timed_out = let* () = Lwt_unix.sleep timeout in Lwt.return `Timeout in
                let* outcome = Lwt.pick [finished; timed_out] in
                match outcome with
                | `Timeout ->
                  process#terminate;
                  let* _ = process#status in
                  Lwt.return (response request.request_id 124 (Some "Editor request timed out") None)
                | `Finished (Unix.WEXITED 0) ->
                  begin match Editor_buffer.read_temporary temporary with
                  | Ok content -> Lwt.return (response request.request_id 0 None (Some content))
                  | Error message -> Lwt.return (response request.request_id 74 (Some message) None)
                  end
                | `Finished (Unix.WEXITED code) ->
                  Lwt.return (response request.request_id code (Some (Printf.sprintf "Editor exited with status %d" code)) None)
                | `Finished (Unix.WSIGNALED signal | Unix.WSTOPPED signal) ->
                  Lwt.return (response request.request_id (128 + signal) (Some (Printf.sprintf "Editor stopped by signal %d" signal)) None))
              (fun () ->
                Lwt.catch
                  (fun () ->
                    if process#state = Lwt_process.Running then process#terminate;
                    let* _ = process#status in
                    Lwt.return_unit)
                  (fun _ -> Lwt.return_unit)))
          (fun exn -> Lwt.return (response request.request_id 127 (Some (Printexc.to_string exn)) None)))
      (fun () -> Editor_buffer.cleanup_temporary temporary; Lwt.return_unit)
