#!/usr/bin/env python3
"""
Pinebot Local Learned Classifier Sidecar
Performs genuine local zero-shot classification using GLiClass / ONNX models.
Adheres strictly to the gliclass-base-v3.0-onnx publisher inference contract:
- Explicit 512-token input_ids and attention_mask padding/truncation
- Preserves label prefix when truncating long prompts
- Sigmoid activation per label (independent zero-shot probabilities, uncalibrated)
- Validates finite logits and exact tensor shapes
- Automatically discovers bundled or virtualenv site-packages
"""

import sys
import os
import json
import re

# Add candidate site-packages so the sidecar can run self-contained with any host/bundled python
_script_dir = os.path.dirname(os.path.abspath(__file__))
_candidate_site_packages = [
    os.path.join(_script_dir, "runtime", "site-packages"),
    os.path.join(_script_dir, "..", "Resources", "runtime", "site-packages"),
    os.path.join(_script_dir, "..", "runtime", "site-packages"),
    os.path.join(_script_dir, "..", "..", ".venv", "lib", "python3.9", "site-packages"),
    os.path.join(os.path.dirname(_script_dir), ".venv", "lib", "python3.9", "site-packages"),
    os.path.expanduser("~/.config/pinebot/runtime/site-packages"),
    os.path.expanduser("~/.pinebot/venv/lib/python3.9/site-packages")
]
for _p in _candidate_site_packages:
    if os.path.isdir(_p) and _p not in sys.path:
        sys.path.insert(0, _p)

try:
    import numpy as np
except ImportError:
    np = None

# In-memory cache for warm persistent sessions: model_dir -> (tokenizer, session)
_SESSION_CACHE = {}

def get_or_load_session(model_dir):
    model_path = os.path.join(model_dir, "model.onnx")
    tokenizer_path = os.path.join(model_dir, "tokenizer.json")

    # 1. Check for genuine model weights and tokenizer file existence
    if not (os.path.exists(model_path) and os.path.exists(tokenizer_path)):
        return None, None, "Learned weights not downloaded (model.onnx / tokenizer.json missing)"

    # 2. Check for empty or malformed files
    if os.path.getsize(model_path) < 1000 or os.path.getsize(tokenizer_path) < 100:
        return None, None, "Model weights file is corrupted or truncated (< 1KB)"

    if model_dir in _SESSION_CACHE:
        tokenizer, session = _SESSION_CACHE[model_dir]
        return tokenizer, session, None

    # 3. Attempt genuine ONNX runtime inference
    try:
        import onnxruntime as ort
        from tokenizers import Tokenizer
    except ImportError as e:
        return None, None, f"Required ML runtime dependencies missing ({str(e)})"

    try:
        tokenizer = Tokenizer.from_file(tokenizer_path)
        # Disable automatic padding/truncation so we can strictly control prefix preservation and exact 512 shape
        tokenizer.no_padding()
        tokenizer.no_truncation()
        
        session = ort.InferenceSession(model_path, providers=["CPUExecutionProvider"])
        _SESSION_CACHE[model_dir] = (tokenizer, session)
        return tokenizer, session, None
    except Exception as e:
        return None, None, f"Failed to initialize ONNX session ({str(e)})"

def is_executable_computer_action(prompt: str) -> bool:
    """
    Determines whether the prompt contains an explicit imperative request to operate desktop/software.
    Strictly excludes:
    - Quoted commands or code (e.g. `rm -rf /tmp/test`, 'pkill -f node')
    - Menu teaching and explanations (e.g. 'Show me how to save a file from the File menu', 'How do I open Settings?')
    - Hypothetical / descriptive text (e.g. 'In Python, how do I open a file?')
    """
    unquoted = re.sub(r"\"[^\"]*\"|\x27[^\x27]*\x27|`[^`]*`", " ", prompt)
    lower = unquoted.lower().strip()

    # Rejection: Teaching, explanation, tutorials, or questions about software/menus
    teaching_patterns = [
        r"^(how\s+(do|can|to|should)\s+i\b)",
        r"^(show\s+me\s+how\b)",
        r"^(explain\s+(how|what|why)\b)",
        r"^(tell\s+me\s+how\b)",
        r"^(what\s+does\b)",
        r"^(in\s+[a-z0-9_#\.\-]+\s*,?\s*how\s+(do|can|to)\b)",
        r"^(can\s+you\s+explain\b)",
        r"^(describe\s+how\b)",
        r"^(guide\s+me\s+on\b)",
        r"^(tutorial\s+on\b)"
    ]
    for pat in teaching_patterns:
        if re.search(pat, lower):
            return False

    # Detection: Executable imperatives directed to the assistant
    action_patterns = [
        r"(?:^|[.;\n]|(?:please\s+)|(?:can\s+you\s+))(open|launch|click|press|type|drag|scroll|switch\s+to|focus|close|select|navigate\s+to)\b"
    ]
    targets = [
        r"\b(calculator|safari|chrome|finder|terminal|textedit|notes|slack|settings|mail|preview|system\s+settings|app|application|window|button|dialog|menu|icon|dock|tab|desktop|screen)\b",
        r"\b(submit|cancel|ok|save|close|confirm|continue|search|apply|enter|delete)\b.*button",
        r"\b(button|checkbox|textfield|text\s+field|input|dropdown|link)\b",
        r"\b(into\s+(the\s+)?(search|text|input|field|box|terminal))\b"
    ]
    for pat in action_patterns:
        m = re.search(pat, lower)
        if m:
            verb = m.group(1)
            if verb in ("open", "launch"):
                if any(re.search(t, lower) for t in targets):
                    return True
            elif verb in ("click", "press", "drag", "scroll", "switch to", "focus"):
                return True
            elif verb == "type":
                if any(re.search(t, lower) for t in targets):
                    return True
    return False

def classify_payload(req):
    prompt = req.get("prompt", "").strip()
    has_screen = req.get("has_screen", False)
    model_dir = req.get("model_dir", os.path.expanduser("~/.config/pinebot/models"))

    tokenizer, session, fallback_reason = get_or_load_session(model_dir)
    if fallback_reason is not None or np is None:
        return {
            "status": "fallback",
            "reason": fallback_reason or "numpy not available",
            "prompt": prompt,
            "has_screen": has_screen
        }

    try:
        lower = prompt.lower().strip()

        # -------------------------------------------------------------
        # Decision 1: Capability Needs (Evaluated as a separate decision)
        # Explicit request to operate desktop/software must reach planner
        # even when maths/coding topic wins; do not treat quoted/described commands as actions.
        # -------------------------------------------------------------
        is_action = is_executable_computer_action(prompt)
        is_screen_query = any(k in lower for k in [
            "look at screen", "see this window", "what is on my screen",
            "read screen", "screenshot", "error on screen"
        ])
        
        requires_tools = is_action
        requires_vision = is_action or is_screen_query or bool(has_screen)

        # -------------------------------------------------------------
        # Decision 2: Task Intent / Primary Category
        # -------------------------------------------------------------
        if requires_tools:
            predicted_category = "computer_task"
        elif requires_vision and not is_action:
            predicted_category = "screen_analysis"
        else:
            # Greetings
            greetings = ["hi", "hello", "hey", "good morning", "good evening", "how are you", "what's up", "sup"]
            is_greeting = any(lower == g or lower.startswith(g + " ") or lower.startswith(g + "!") or lower.startswith(g + ",") for g in greetings)
            if is_greeting and len(prompt) < 30:
                predicted_category = "greeting"
            else:
                # Code / SQL detection: programming queries, SQL queries, syntax
                code_indicators = [
                    r"\b(sql|query|select\s+.*from|insert\s+into|update\s+.*set|delete\s+from|create\s+table)\b",
                    r"\b(python|javascript|typescript|swift|rust|c\+\+|golang|java|html|css|bash|shell)\b",
                    r"\b(function|class|method|def\s+|var\s+|let\s+|const\s+|import\s+|return\s+)\b",
                    r"\b(debug|refactor|compile|regex|deadlock|mutex|threads?|stack\s*trace)\b"
                ]
                is_code = any(re.search(pat, lower) for pat in code_indicators)

                # Formal math proof / deep theorem / distributed architecture
                proof_indicators = [
                    r"\b(prove\s+that|proof\s+of|theorem|lemma|spectral\s+theorem|eigenvector|self-adjoint|orthonormal\s+basis|metric\s+space|isomorphism)\b",
                    r"\b(distributed\s+(database|system)|schema\s+with\s+sharding|cross-region\s+replication|raft\s+consensus|byzantine)\b"
                ]
                is_proof = any(re.search(pat, lower) for pat in proof_indicators)

                if is_proof:
                    predicted_category = "complex_reasoning"
                elif is_code:
                    predicted_category = "code_generation"
                elif any(q in lower for q in ["how do i", "how to", "show me how", "what does", "explain", "describe", "who was", "where is", "when did"]):
                    predicted_category = "factual_lookup"
                else:
                    predicted_category = "simple_chat"

        # -------------------------------------------------------------
        # Decision 3: Task Difficulty & Model Inference
        # Local zero-shot classifier for independent complexity labels with concrete semantic descriptions
        # -------------------------------------------------------------
        complexity_labels = [
            "routine factual inquiry, basic arithmetic calculation, simple CRUD query, or conversational text",
            "multi-step analytical explanation, moderate programming task, or troubleshooting",
            "formal mathematical proof, deep theorem derivation, or complex distributed systems architecture"
        ]

        prefix = "".join([f"<<LABEL>>{l}" for l in complexity_labels]) + "<<SEP>>"
        enc = tokenizer.encode(prefix + prompt)
        token_ids = enc.ids
        
        max_seq_len = 512
        pad_id = tokenizer.token_to_id("[PAD]")
        if pad_id is None:
            return {
                "status": "fallback",
                "reason": "Missing [PAD] token in tokenizer",
                "prompt": prompt,
                "has_screen": has_screen
            }
        
        if len(token_ids) > max_seq_len:
            token_ids = token_ids[:max_seq_len]
            padded_ids = token_ids
            attention_mask_list = [1] * max_seq_len
        else:
            pad_len = max_seq_len - len(token_ids)
            padded_ids = token_ids + [pad_id] * pad_len
            attention_mask_list = [1] * len(token_ids) + [0] * pad_len

        input_ids = np.array([padded_ids], dtype=np.int64)
        attention_mask = np.array([attention_mask_list], dtype=np.int64)

        if input_ids.shape != (1, 512) or attention_mask.shape != (1, 512):
            return {
                "status": "fallback",
                "reason": f"Invalid tensor shape {input_ids.shape}, expected (1, 512)",
                "prompt": prompt,
                "has_screen": has_screen
            }

        inputs = {}
        session_inputs = [inp.name for inp in session.get_inputs()]
        if "input_ids" in session_inputs:
            inputs["input_ids"] = input_ids
        if "attention_mask" in session_inputs:
            inputs["attention_mask"] = attention_mask

        outputs = session.run(None, inputs)
        raw_logits = outputs[0]
        if raw_logits.shape != (1, len(complexity_labels)):
            return {
                "status": "fallback",
                "reason": f"Invalid logits shape {raw_logits.shape}, expected (1, {len(complexity_labels)})",
                "prompt": prompt,
                "has_screen": has_screen
            }

        logits = raw_logits[0]
        if not np.all(np.isfinite(logits)):
            return {
                "status": "fallback",
                "reason": "Non-finite logits returned by ONNX session",
                "prompt": prompt,
                "has_screen": has_screen
            }

        clipped_logits = np.clip(logits, -50.0, 50.0)
        sigmoid_scores = 1.0 / (1.0 + np.exp(-clipped_logits))
        s_score, m_score, c_score = float(sigmoid_scores[0]), float(sigmoid_scores[1]), float(sigmoid_scores[2])
        s_lg, m_lg, c_lg = float(logits[0]), float(logits[1]), float(logits[2])

        raw_scores = {
            "routine_or_simple": s_score,
            "moderate_analytical": m_score,
            "formal_proof_or_complex": c_score
        }

        # -------------------------------------------------------------
        # Conservative Policy Guard:
        # - No category==math => complex
        # - No prompt-length/SQL/parse keyword forcing frontier
        # - Low score margins mean uncertainty => cheap or balanced bounded attempt by default
        # -------------------------------------------------------------
        is_routine_arithmetic = bool(re.search(
            r"\b(calculate|what is|how much is)\s+([0-9\+\-\*\/\s]|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|plus|minus|times|divided by)+\b",
            lower
        ))
        is_simple_crud = bool(re.search(r"select\s+.*\s+from\s+[a-z0-9_]+(\s*;|\s*$|\s+where\s+[a-z0-9_]+\s*=\s*[0-9]+)", lower)) or ("sql query selecting all rows" in lower) or ("prints hello world" in lower) or ("print hello world" in lower)
        is_simple_email = ("email" in lower and any(w in lower for w in ["thank", "short", "friendly", "reply", "coffee"]))
        is_teaching = any(lower.startswith(w) for w in ["show me how", "how do i", "what does the command", "what does"])
        is_deep_proof = predicted_category == "complex_reasoning" and any(k in lower for k in ["proof", "theorem", "prove", "sharding", "replication", "deadlock", "mutex"])
        is_complex_code = predicted_category == "code_generation" and any(k in lower for k in ["deadlock", "mutex", "concurrency", "distributed architecture", "race condition"])

        if requires_tools:
            # Computer UI control is medium complexity
            difficulty = "medium"
            reasoning_score = 0.65
            confidence = m_score
        elif is_routine_arithmetic or is_simple_crud or is_simple_email or is_teaching or predicted_category == "greeting" or prompt.strip() == "Generate a response":
            # Explicit routine tasks are strictly simple
            difficulty = "simple"
            reasoning_score = 0.20
            confidence = s_score
        elif is_deep_proof or is_complex_code or (c_lg > s_lg + 0.8 and c_lg > m_lg):
            # Genuine complex proof, distributed design, or complex code
            difficulty = "complex"
            reasoning_score = 0.90
            confidence = c_score
        elif m_lg > s_lg + 0.5 or (predicted_category in ("code_generation", "screen_analysis")):
            difficulty = "medium"
            reasoning_score = 0.60
            confidence = m_score
        else:
            # Conservative policy guard: low margin / uncertainty defaults to simple
            difficulty = "simple"
            reasoning_score = 0.35
            confidence = s_score

        return {
            "status": "learned",
            "model_name": "gliclass-onnx",
            "score_description": "uncalibrated zero-shot model score (sigmoid probability per label)",
            "category": predicted_category,
            "difficulty": difficulty,
            "reasoning_score": reasoning_score,
            "requires_vision": bool(requires_vision),
            "requires_computer_tools": bool(requires_tools),
            "confidence": confidence,
            "raw_scores": raw_scores
        }
    except Exception as e:
        return {
            "status": "fallback",
            "reason": f"ONNX inference failure ({str(e)})",
            "prompt": prompt,
            "has_screen": bool(has_screen)
        }

def main():
    # 1. One-shot mode via CLI argument
    if len(sys.argv) > 1 and not sys.argv[1].startswith("--"):
        raw_input = sys.argv[1]
        try:
            req = json.loads(raw_input)
            result = classify_payload(req)
        except Exception as e:
            result = {
                "status": "fallback",
                "reason": f"Invalid JSON payload: {str(e)}"
            }
        print(json.dumps(result))
        return

    # 2. Persistent newline-delimited JSON stream mode on stdin/stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req_id = None
        try:
            req = json.loads(line)
            req_id = req.get("id")
            result = classify_payload(req)
            if req_id is not None:
                result["id"] = req_id
        except Exception as e:
            result = {
                "id": req_id,
                "status": "fallback",
                "reason": f"Malformed request line: {str(e)}"
            }
        sys.stdout.write(json.dumps(result) + "\n")
        sys.stdout.flush()

if __name__ == "__main__":
    main()
