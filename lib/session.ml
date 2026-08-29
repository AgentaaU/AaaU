(** Session implementation *)

open Lwt.Syntax

let (>>=) = Lwt.(>>=)

module Lwt_queue = struct
  type 'a t = {
    queue : 'a Queue.t;
    condition : unit Lwt_condition.t;
    lock : Lwt_mutex.t;
  }

  let create () =
    {
      queue = Queue.create ();
      condition = Lwt_condition.create ();
      lock = Lwt_mutex.create ();
    }

  let push item t =
    Lwt_mutex.with_lock t.lock (fun () ->
      Queue.push item t.queue;
      Lwt_condition.signal t.condition ();
      Lwt.return_unit
    )

  let rec pop t =
    let* result = Lwt_mutex.with_lock t.lock (fun () ->
      if Queue.is_empty t.queue then
        Lwt.return_none
      else
        Lwt.return_some (Queue.pop t.queue)
    ) in
    match result with
    | Some item -> Lwt.return item
    | None ->
      let* () = Lwt_condition.wait t.condition in
      pop t
end

type client = {
  socket : Lwt_unix.file_descr;
  addr : string;
  user_info : Auth.user_info;
  connected_at : float;
  mutable last_activity : float;
}

type editor_provider = {
  socket : Lwt_unix.file_descr;
  token : string;
  stopped : unit Lwt.t;
  stop : unit Lwt.u;
}

type session = {
  session_id : string;
  audit : Audit.t;

  (* PTY *)
  pty : Pty.t;
  agent_pid : int;
  creator : Auth.user_info;
  agent_uid : int;

  (* Client management *)
  clients : (Lwt_unix.file_descr, client) Hashtbl.t;
  clients_lock : Lwt_mutex.t;

  (* Communication *)
  input_queue : string Lwt_queue.t;
  output_buffer : Buffer.t;
  output_cond : unit Lwt_condition.t;
  mutable last_sent_pos : int;  (* Track what was already broadcast *)

  (* Dedicated editor channel; never mixed with PTY bytes. *)
  mutable editor_provider : editor_provider option;
  editor_provider_lock : Lwt_mutex.t;
  editor_request_lock : Lwt_mutex.t;

  (* Control *)
  mutable running : bool;
  mutable shutdown_complete : bool;
}

type t = session

let get_id s = s.session_id
let get_clients s = Hashtbl.fold (fun _ c acc -> c :: acc) s.clients []
let get_agent_pid s = Some s.agent_pid

let authorize_editor_provider ~creator_uid user_info = user_info.Auth.uid = creator_uid
let authorize_editor_request ~agent_uid ~agent_session_id user_info ~peer_session_id =
  user_info.Auth.uid = agent_uid && peer_session_id = agent_session_id
let editor_request_authorized t user_info ~peer_session_id =
  authorize_editor_request ~agent_uid:t.agent_uid ~agent_session_id:t.agent_pid user_info ~peer_session_id

let close_noerr fd =
  Lwt.catch (fun () -> Lwt_unix.close fd) (fun _ -> Lwt.return_unit)

let stop_provider provider =
  if Lwt.is_sleeping provider.stopped then Lwt.wakeup_later provider.stop ();
  close_noerr provider.socket

let signal_process_group pid signal =
  try Unix.kill (-pid) signal with _ -> ()

let rec reap_process pid attempts =
  if attempts <= 0 then
    ()
  else
    match Unix.waitpid [Unix.WNOHANG] pid with
    | 0, _ ->
      Unix.sleepf 0.1;
      reap_process pid (attempts - 1)
    | _, _ -> ()

let compact_output_buffer buffer ~last_sent_pos =
  if Buffer.length buffer <= 100000 then
    last_sent_pos
  else
    let content = Buffer.contents buffer in
    let dropped = String.length content / 2 in
    let keep = String.sub content dropped (String.length content - dropped) in
    Buffer.reset buffer;
    Buffer.add_string buffer keep;
    max 0 (last_sent_pos - dropped)

(* Read agent output from PTY *)
let rec pty_read_loop (t : session) =
  if not t.running then
    Lwt.return_unit
  else
    let buf = Bytes.create 4096 in
    let* n =
      Lwt.catch
        (fun () -> Pty.read t.pty buf 0 4096)
        (fun e ->
          (* EIO is expected when the agent process closes the PTY *)
          let is_expected_error = match e with
            | Unix.Unix_error (Unix.EIO, _, _) -> true
            | _ -> false
          in
          let* () =
            if is_expected_error then
              Logs_lwt.debug (fun m -> m "PTY closed (agent exited)")
            else
              Logs_lwt.err (fun m -> m "PTY read error: %s" (Printexc.to_string e))
          in
          Lwt.return 0)
    in

    if n = 0 then (
      (* EOF - agent exited *)
      if t.running then begin
        t.running <- false;
        Lwt_condition.broadcast t.output_cond ();
        let* () = Logs_lwt.info (fun m -> m "Agent EOF in session %s" t.session_id) in
        (* Close all client sockets so they get EOF and can exit *)
        let fds_to_close = ref [] in
        let* () =
          Lwt_mutex.with_lock t.clients_lock (fun () ->
            Hashtbl.iter (fun fd _ ->
              fds_to_close := fd :: !fds_to_close
            ) t.clients;
            Hashtbl.clear t.clients;
            Lwt.return_unit
          )
        in
        (* Close sockets outside the lock *)
        List.iter (fun fd ->
          try Unix.close (Lwt_unix.unix_file_descr fd) with _ -> ()
        ) !fds_to_close;
        Lwt.return_unit
      end else
        Lwt.return_unit
    ) else (
      let data = Bytes.sub_string buf 0 n in

      (* Save to buffer *)
      Buffer.add_string t.output_buffer data;
      t.last_sent_pos <- compact_output_buffer t.output_buffer ~last_sent_pos:t.last_sent_pos;

      (* Notify broadcast immediately for every output *)
      Lwt_condition.broadcast t.output_cond ();

      (* Yield to let broadcast run, then continue *)
      let* () = Lwt.pause () in
      pty_read_loop t
    )

(* Write user input to PTY - handles partial writes with timeout *)
let rec pty_write_loop (t : session) =
  if not t.running then
    Lwt.return_unit
  else
    let* input = Lwt_queue.pop t.input_queue in
    let data = Bytes.of_string input in
    let len = Bytes.length data in
    let rec write_all offset remaining =
      if remaining = 0 then
        Lwt.return_unit
      else
        let* written = Pty.write t.pty data offset remaining in
        if written > 0 then
          write_all (offset + written) (remaining - written)
        else
          Lwt.return_unit
    in
    let* () =
      Lwt.catch
        (fun () -> write_all 0 len)
        (fun e ->
          let* () = Logs_lwt.warn (fun m -> m "PTY write failed: %s" (Printexc.to_string e)) in
          Lwt.return_unit)
    in
    pty_write_loop t

(* Broadcast output to all clients - with timeout to prevent blocking *)
let rec broadcast_loop (t : session) =
  if not t.running then
    Lwt.return_unit
  else
    let* () = Lwt_condition.wait t.output_cond in
    if not t.running then
      Lwt.return_unit
    else
      (* Get only new data since last broadcast *)
      let buf_len = Buffer.length t.output_buffer in
      if buf_len > t.last_sent_pos then (
        let data = Buffer.sub t.output_buffer t.last_sent_pos (buf_len - t.last_sent_pos) in
        t.last_sent_pos <- buf_len;
        let* clients =
          Lwt_mutex.with_lock t.clients_lock (fun () ->
            Lwt.return (Hashtbl.fold (fun fd c acc -> (fd, c) :: acc) t.clients [])
          )
        in
        let dead = ref [] in

        let send_to_client fd (client : client) =
          Lwt.pick [
            (* Try to write with timeout *)
            (let rec write_all offset remaining =
               if remaining = 0 then
                 Lwt.return_unit
               else
                 let* written = Lwt_unix.write client.socket
                   (Bytes.unsafe_of_string data) offset remaining in
                 if written > 0 then
                   write_all (offset + written) (remaining - written)
                 else
                   Lwt.return_unit
             in
             Lwt.catch
               (fun () -> write_all 0 (String.length data))
               (fun _ ->
                 dead := fd :: !dead;
                 Lwt.return_unit));
            (* Timeout after 5 seconds - client is too slow *)
            (let* () = Lwt_unix.sleep 5.0 in
             let* () = Logs_lwt.warn (fun m -> m "Client %s slow, disconnecting" client.addr) in
             dead := fd :: !dead;
             Lwt.return_unit);
          ]
        in

        let rec send_all = function
          | [] -> Lwt.return_unit
          | (fd, client) :: rest ->
            let* () = send_to_client fd client in
            send_all rest
        in
        let* () = send_all clients in
        let* () =
          if !dead = [] then
            Lwt.return_unit
          else
            Lwt_mutex.with_lock t.clients_lock (fun () ->
              List.iter (fun fd ->
                Hashtbl.remove t.clients fd;
                try Unix.close (Lwt_unix.unix_file_descr fd) with _ -> ()
              ) !dead;
              Lwt.return_unit
            )
        in
        broadcast_loop t
      ) else
        broadcast_loop t

let create ~session_id ~creator ~agent_user ~editor_socket_path ~program ~args ~rows ~cols ~audit =
  let* () = Logs_lwt.info (fun m -> m "Creating session %s" session_id) in

  (* Open PTY *)
  match Pty.open_pty () with
  | Error e -> Lwt.return_error e
  | Ok (pty, slave) ->
    (* Get agent user info for home directory *)
    let agent_home = 
      try (Unix.getpwnam agent_user).Unix.pw_dir
      with Not_found -> 
        try Unix.getenv "HOME"
        with Not_found -> 
          "/tmp"
    in
    let agent_uid =
      try (Unix.getpwnam agent_user).Unix.pw_uid with Not_found -> -1
    in
    (* Ensure home directory exists *)
    let () = 
      try 
        if not (Sys.file_exists agent_home) then
          Unix.mkdir agent_home 0o755
      with _ -> ()
    in
    (* Start agent with minimal environment - login shell will set the rest *)
    let env = [
      "TERM", "xterm-256color";
      "COLORTERM", "truecolor";
      "TERM_PROGRAM", "aaau";
      "SESSION_ID", session_id;
      "AAAU_SESSION_ID", session_id;
      "AAAU_EDITOR_SOCKET", editor_socket_path;
      "EDITOR", "aaau-editor";
      "VISUAL", "aaau-editor";
      "SHELL", "/bin/bash";
    ] in

    match Pty.fork_agent
      ~slave
      ~user:agent_user
      ~program
      ~args
      ~env
      ~rows
      ~cols
    with
    | Error e -> 
      (* Close PTY on fork failure *)
      let* () = Pty.close pty in
      Lwt.return_error e
    | Ok pid ->
      let session = {
        session_id;
        audit;
        pty;
        agent_pid = pid;
        creator;
        agent_uid;
        clients = Hashtbl.create 10;
        clients_lock = Lwt_mutex.create ();
        input_queue = Lwt_queue.create ();
        output_buffer = Buffer.create 102400;
        output_cond = Lwt_condition.create ();
        last_sent_pos = 0;
        editor_provider = None;
        editor_provider_lock = Lwt_mutex.create ();
        editor_request_lock = Lwt_mutex.create ();
        running = true;
        shutdown_complete = false;
      } in

      (* PTY slave is configured in fork_agent; master doesn't need raw mode *)
      ();

      (* Audit record *)
      let* () = Audit.log audit {
        timestamp = Unix.time ();
        source = "system";
        user = creator.Auth.username;
        session_id;
        command_type = "session_start";
        content = Printf.sprintf "Agent PID %d" pid;
        metadata = ["pty", (Pty.get_slave_path pty :> string)];
      } in

      (* Start processing loops *)
      Lwt.async (fun () -> pty_read_loop session);
      Lwt.async (fun () -> pty_write_loop session);
      Lwt.async (fun () -> broadcast_loop session);

      Lwt.return_ok session

let add_client t ~socket ~addr ~user_info =
  Lwt_mutex.with_lock t.clients_lock (fun () ->
    if Hashtbl.length t.clients >= 10 then
      Lwt.return_error "Session full"
    else
      let client = {
        socket;
        addr;
        user_info;
        connected_at = Unix.time ();
        last_activity = Unix.time ();
      } in

      Hashtbl.add t.clients socket client;

      (* Send history output *)
      let history = Buffer.contents t.output_buffer in
      let* () =
        Lwt.catch
          (fun () ->
            let rec write_all offset remaining =
              if remaining = 0 then
                Lwt.return_unit
              else
                let* written = Lwt_unix.write socket 
                  (Bytes.unsafe_of_string history) offset remaining in
                if written > 0 then
                  write_all (offset + written) (remaining - written)
                else
                  Lwt.return_unit
            in
            if String.length history > 0 then
              write_all 0 (String.length history)
            else
              Lwt.return_unit)
          (fun _ -> Lwt.return_unit)
      in
      Lwt.return_ok client
  )

let remove_client t (client : client) =
  Lwt_mutex.with_lock t.clients_lock (fun () ->
    if Hashtbl.mem t.clients client.socket then
      Hashtbl.remove t.clients client.socket;
    Lwt.return_unit
  )

(* Check if agent is alive *)
let is_alive t =
  try
    Unix.kill t.agent_pid 0;
    t.running
  with Unix.Unix_error _ -> false

let shutdown t =
  if t.shutdown_complete then
    Lwt.return_unit
  else
    let () =
      t.running <- false;
      t.shutdown_complete <- true
    in
    Lwt_condition.broadcast t.output_cond ();

    let* () =
      Lwt_mutex.with_lock t.editor_provider_lock (fun () ->
        match t.editor_provider with
        | None -> Lwt.return_unit
        | Some provider ->
          t.editor_provider <- None;
          stop_provider provider)
    in

    (* Terminate the agent process group so descendants cannot outlive the session. *)
    signal_process_group t.agent_pid Sys.sigterm;
    let* () = Lwt_unix.sleep 1.0 in
    signal_process_group t.agent_pid Sys.sigkill;
    let () = reap_process t.agent_pid 10 in

    (* Close PTY *)
    let* () = Pty.close t.pty in

    (* Disconnect all clients *)
    let* () =
      Lwt_mutex.with_lock t.clients_lock (fun () ->
        Hashtbl.iter (fun fd _ ->
          try Unix.close (Lwt_unix.unix_file_descr fd) with _ -> ()) t.clients;
        Hashtbl.clear t.clients;
        Lwt.return_unit
      )
    in

    (* Flush audit logs *)
    Audit.flush t.audit

let register_editor_provider t ~socket ~user_info =
  if not (authorize_editor_provider ~creator_uid:t.creator.Auth.uid user_info) then
    Lwt.return_error "Only the session creator may provide editor forwarding"
  else if not t.running then
    Lwt.return_error "Session is not running"
  else
    Lwt_mutex.with_lock t.editor_provider_lock (fun () ->
      let stopped, stop = Lwt.wait () in
      let provider = {
        socket;
        token = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string;
        stopped;
        stop;
      } in
      let previous = t.editor_provider in
      t.editor_provider <- Some provider;
      let* () = match previous with None -> Lwt.return_unit | Some old -> stop_provider old in
      Lwt.return_ok stopped)

let clear_provider_if_current t provider =
  Lwt_mutex.with_lock t.editor_provider_lock (fun () ->
    match t.editor_provider with
    | Some current when current.token = provider.token ->
      t.editor_provider <- None;
      stop_provider provider
    | _ -> Lwt.return_unit)

let editor_failure request_id message =
  { Editor_protocol.request_id; status = 69; error = Some message; content = None }

let forward_editor_request t ~user_info ~peer_session_id content =
  let unauthorized = not (editor_request_authorized t user_info ~peer_session_id) in
  if unauthorized then
    Lwt.return (editor_failure "unauthorized" "Only the configured agent account may request editing")
  else if not t.running then
    Lwt.return (editor_failure "unavailable" "Session is not running")
  else
    Lwt_mutex.with_lock t.editor_request_lock (fun () ->
      let request_id = Uuidm.v4_gen (Random.State.make_self_init ()) () |> Uuidm.to_string in
      let audit_completion response = Audit.log t.audit {
        timestamp = Unix.time (); source = "system"; user = t.creator.Auth.username;
        session_id = t.session_id; command_type = "editor_complete"; content = request_id;
        metadata = ["outcome", string_of_int response.Editor_protocol.status];
      } in
      let* () = Audit.log t.audit {
        timestamp = Unix.time (); source = "agent"; user = user_info.Auth.username;
        session_id = t.session_id; command_type = "editor_start"; content = request_id;
        metadata = ["operator", t.creator.Auth.username; "bytes", string_of_int (String.length content)];
      } in
      let* provider = Lwt_mutex.with_lock t.editor_provider_lock (fun () -> Lwt.return t.editor_provider) in
      match provider with
      | None ->
        let response = editor_failure request_id "Editor forwarding unavailable" in
        let* () = audit_completion response in
        Lwt.return response
      | Some provider ->
        let request = { Editor_protocol.request_id; content } in
        let exchange =
          let* sent = Editor_protocol.write_frame provider.socket (Editor_protocol.request_to_string request) in
          match sent with
          | Error message -> Lwt.return_error message
          | Ok () ->
            let* payload = Editor_protocol.read_frame provider.socket in
            begin match payload with
            | Error _ as error -> Lwt.return error
            | Ok payload ->
              begin match Editor_protocol.response_of_string payload with
              | Error _ as error -> Lwt.return error
              | Ok response when response.Editor_protocol.request_id <> request_id ->
                Lwt.return_error "Mismatched editor response ID"
              | Ok response -> Lwt.return_ok response
              end
            end
        in
        let timeout =
          let* () = Lwt_unix.sleep Editor_protocol.request_timeout_seconds in
          Lwt.return_error "Editor request timed out"
        in
        let* result = Lwt.pick [exchange; timeout] in
        let response = match result with
          | Ok response -> response
          | Error message -> editor_failure request_id message
        in
        let* () =
          match result with
          | Ok _ -> Lwt.return_unit
          | Error _ -> clear_provider_if_current t provider
        in
        let* () = audit_completion response in
        Lwt.return response)

let handle_client_input t ~client ~data =
  client.last_activity <- Unix.time ();

  let msg = Protocol.decode_client data in

  match msg with
  | Protocol.Input text ->
    (* Permission check *)
    (match client.user_info.Auth.permission with
     | Auth.ReadOnly ->
       let* () =
         Lwt.catch
           (fun () ->
             let err = Protocol.encode_server (Protocol.Error "Read-only mode") in
             let bytes = Bytes.of_string err in
             Lwt_unix.write client.socket bytes 0 (String.length err) >>= fun _ ->
             Lwt.return_unit)
           (fun _ -> Lwt.return_unit)
       in
       Lwt.return_unit

     | Auth.Interactive | Auth.Admin ->
       (* Audit record *)
       let* () = Audit.log t.audit {
         timestamp = Unix.time ();
         source = "human";
         user = client.user_info.Auth.username;
         session_id = t.session_id;
         command_type = "input";
         content = text;
         metadata = [];
       } in

       (* Add to input queue *)
       Lwt_queue.push text t.input_queue)

  | Protocol.Resize { rows; cols } ->
    Pty.set_terminal_size (Pty.fd t.pty) ~rows ~cols;
    Lwt.return_unit

  | Protocol.Ping ->
    let pong = Protocol.encode_server Protocol.Pong in
    let* () =
      Lwt.catch
        (fun () ->
          let bytes = Bytes.of_string pong in
          Lwt_unix.write client.socket bytes 0 (String.length pong) >>= fun _ ->
          Lwt.return_unit)
        (fun _ -> Lwt.return_unit)
    in
    Lwt.return_unit

  | Protocol.GetStatus ->
    let status = `Assoc [
      "session_id", `String t.session_id;
      "clients", `Int (Hashtbl.length t.clients);
      "agent_alive", `Bool (is_alive t);
    ] in
    let resp = Protocol.encode_server (Protocol.Status status) in
    let* () =
      Lwt.catch
        (fun () ->
          let bytes = Bytes.of_string resp in
          Lwt_unix.write client.socket bytes 0 (String.length resp) >>= fun _ ->
          Lwt.return_unit)
        (fun _ -> Lwt.return_unit)
    in
    Lwt.return_unit

  | Protocol.ForceKill ->
    (match client.user_info.Auth.permission with
     | Auth.Admin ->
       t.running <- false;
       Lwt_condition.broadcast t.output_cond ();
       let* () = shutdown t in
       Lwt.return_unit
     | _ ->
       let err = Protocol.encode_server (Protocol.Error "Permission denied") in
       let* () =
         Lwt.catch
           (fun () ->
             let bytes = Bytes.of_string err in
             Lwt_unix.write client.socket bytes 0 (String.length err) >>= fun _ ->
             Lwt.return_unit)
           (fun _ -> Lwt.return_unit)
       in
       Lwt.return_unit)

  | Protocol.Unknown _ ->
    Lwt.return_unit
