#!/usr/bin/env python3
import sys
import json
import time

def main():
    if len(sys.argv) < 2:
        sys.exit(1)
        
    mode = sys.argv[1]
    
    if mode == "timeout_then_respond":
        # Request 1: Read and ignore (causing client timeout)
        line1 = sys.stdin.readline()
        if not line1:
            sys.exit(0)
        # Sleep long enough for client's 100ms timeout to fire
        time.sleep(0.3)
        
        # Request 2: Read and respond with success
        line2 = sys.stdin.readline()
        if not line2:
            sys.exit(0)
        req2 = json.loads(line2)
        resp2 = {
            "jsonrpc": "2.0",
            "id": req2["id"],
            "result": {"status": "ok_second_attempt"}
        }
        sys.stdout.write(json.dumps(resp2) + "\n")
        sys.stdout.flush()
        # Keep process alive
        time.sleep(2)
        
    elif mode == "delayed_notifications_then_result":
        line = sys.stdin.readline()
        req = json.loads(line)
        sess_id = req.get("params", {}).get("sessionId", "test-session")
        
        # Send chunk 1
        notif1 = {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": sess_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "part1_"}
                }
            }
        }
        sys.stdout.write(json.dumps(notif1) + "\n")
        sys.stdout.flush()
        time.sleep(0.05)
        
        # Send chunk 2
        notif2 = {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": sess_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "part2"}
                }
            }
        }
        sys.stdout.write(json.dumps(notif2) + "\n")
        sys.stdout.flush()
        time.sleep(0.05)
        
        # Send prompt final response
        resp = {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"stopReason": "end_turn"}
        }
        sys.stdout.write(json.dumps(resp) + "\n")
        # Process ends/exits cleanly without artificial sleep
        
    elif mode == "notifications_then_result_then_exit_now":
        line = sys.stdin.readline()
        req = json.loads(line)
        sess_id = req.get("params", {}).get("sessionId", "test-session")
        
        # Send chunk 1
        notif1 = {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": sess_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "part1_"}
                }
            }
        }
        sys.stdout.write(json.dumps(notif1) + "\n")
        sys.stdout.flush()
        
        # Send chunk 2
        notif2 = {
            "jsonrpc": "2.0",
            "method": "session/update",
            "params": {
                "sessionId": sess_id,
                "update": {
                    "sessionUpdate": "agent_message_chunk",
                    "content": {"type": "text", "text": "part2"}
                }
            }
        }
        sys.stdout.write(json.dumps(notif2) + "\n")
        sys.stdout.flush()
        
        # Send prompt final response
        resp = {
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"stopReason": "end_turn"}
        }
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()
        
        # Exit immediately to test stdout-drain vs process-exit race
        sys.exit(0)
        
    elif mode == "split_reads":
        line = sys.stdin.readline()
        req = json.loads(line)
        resp = json.dumps({
            "jsonrpc": "2.0",
            "id": req["id"],
            "result": {"coalesced": True}
        }) + "\n"
        # Split write into tiny 3-byte fragments with delays
        for i in range(0, len(resp), 3):
            sys.stdout.write(resp[i:i+3])
            sys.stdout.flush()
            time.sleep(0.01)
            
    elif mode == "agent_unknown_request":
        # Send unsolicited agent request to client
        req = {
            "jsonrpc": "2.0",
            "id": 888,
            "method": "unsupported/action",
            "params": {"foo": "bar"}
        }
        sys.stdout.write(json.dumps(req) + "\n")
        sys.stdout.flush()
        
        # Read client's error response
        client_resp_line = sys.stdin.readline()
        client_resp = json.loads(client_resp_line)
        
        # Echo back verification of received error code
        verification = {
            "jsonrpc": "2.0",
            "method": "test/verified",
            "params": {
                "got_code": client_resp.get("error", {}).get("code"),
                "got_id": client_resp.get("id")
            }
        }
        sys.stdout.write(json.dumps(verification) + "\n")
        sys.stdout.flush()
        time.sleep(0.5)
        
    elif mode == "close_stdout_alive":
        import os
        try:
            sys.stdout.flush()
            os.close(1)
        except OSError:
            pass
        time.sleep(5)
        
    elif mode == "persistent_serve_requests":
        while True:
            line = sys.stdin.readline()
            if not line:
                break
            line_str = line.strip()
            if not line_str:
                continue
            req = json.loads(line_str)
            req_id = req.get("id")
            method = req.get("method")
            sess_id = req.get("params", {}).get("sessionId", "test-session")
            
            if method == "session/prompt":
                notif1 = {
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": sess_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "chunk1"}
                        }
                    }
                }
                sys.stdout.write(json.dumps(notif1) + "\n")
                sys.stdout.flush()
                
                notif2 = {
                    "jsonrpc": "2.0",
                    "method": "session/update",
                    "params": {
                        "sessionId": sess_id,
                        "update": {
                            "sessionUpdate": "agent_message_chunk",
                            "content": {"type": "text", "text": "chunk2"}
                        }
                    }
                }
                sys.stdout.write(json.dumps(notif2) + "\n")
                sys.stdout.flush()
                
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"stopReason": "end_turn"}
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()
            else:
                resp = {
                    "jsonrpc": "2.0",
                    "id": req_id,
                    "result": {"status": "ok"}
                }
                sys.stdout.write(json.dumps(resp) + "\n")
                sys.stdout.flush()

if __name__ == "__main__":
    main()
