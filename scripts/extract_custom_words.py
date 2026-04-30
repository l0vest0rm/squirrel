#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import logging
import re
import sys
import unicodedata
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKSPACE_ROOT = REPO_ROOT.parent
VENV_SITE_PACKAGES = sorted(
    (REPO_ROOT / ".venv" / "lib").glob("python*/site-packages")
)
if VENV_SITE_PACKAGES:
    sys.path.insert(0, str(VENV_SITE_PACKAGES[0]))

try:
    import jieba
    import jieba.posseg as pseg
except ImportError as exc:
    raise SystemExit(
        "jieba is required. Install it into the repo-local .venv first: "
        "python3 -m venv .venv && .venv/bin/pip install jieba"
    ) from exc

jieba.setLogLevel(logging.ERROR)


DEFAULT_INPUT_DIR = (
    WORKSPACE_ROOT
    / "input-helper"
    / "data"
    / "input-gateway"
    / "session-archives"
    / "pending"
    / "post-commit-input"
)
DEFAULT_DICT_FILE = REPO_ROOT / "custom" / "custom_words.dict.yaml"
DEFAULT_REVIEW_FILE = REPO_ROOT / "custom" / "custom_words.review.dict.yaml"
DEFAULT_DICT_SEARCH_ROOTS = (
    REPO_ROOT / "custom",
    REPO_ROOT / "data" / "plum",
)
DEFAULT_SOURCE = "squirrel-mac"
HAN_TEXT_RE = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")

# Keep this list small and obvious. The script is meant to surface domain terms,
# not fully solve Chinese word segmentation.
STOP_PHRASES = {
    "是不是",
    "一下",
    "一个",
    "一些",
    "一种",
    "不是说",
    "不是",
    "不要",
    "为了",
    "为啥",
    "为啥会",
    "为啥还",
    "为啥要",
    "为什么",
    "之前",
    "之前不是",
    "之后",
    "今天",
    "现在",
    "现在的",
    "现在是",
    "什么",
    "他们",
    "你们",
    "你的",
    "你说",
    "你说的",
    "可以",
    "看不见",
    "看不到",
    "看不到了",
    "可能",
    "只是",
    "只有",
    "因为",
    "所以",
    "如果",
    "如果你",
    "如果我",
    "就是",
    "就行了",
    "已经",
    "应该",
    "应该是",
    "怎么",
    "怎么展示",
    "感觉",
    "我觉得",
    "我们",
    "我的",
    "我看",
    "我再",
    "我现在",
    "还是",
    "还是没有",
    "有个",
    "有些",
    "有没有",
    "没有",
    "没必要",
    "不需要",
    "然后",
    "继续",
    "继续吧",
    "这个",
    "这个是",
    "这个问题",
    "这些",
    "这种",
    "那个",
    "那些",
    "能看到",
    "都可以",
    "问题是",
    "本来就",
    "主要是",
    "长时间",
    "里面",
}

LEADING_FUNCTION_CHARS = set(
    "的一是在不了和就都还也再有个这那你我他她它们把被让给对与从到向于将比并"
)
TRAILING_FUNCTION_CHARS = set("的一是在了呢吗吧啊呀哦嘛么哈")
BLOCKED_POS_PREFIXES = ("c", "d", "m", "p", "q", "r", "u", "w", "x")
ALLOWED_POS_PREFIXES = ("eng", "n", "nr", "ns", "nt", "nz", "vn", "v")
MAX_TOKEN_SPAN = 3


@dataclass(frozen=True)
class Record:
    text: str
    app_bundle_id: str


@dataclass(frozen=True)
class Candidate:
    text: str
    line_freq: int
    total_freq: int
    app_count: int
    weight: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Extract frequent Chinese phrases from post-commit input archives "
            "and write them into a review fragment file."
        )
    )
    parser.add_argument("--input-dir", type=Path, default=DEFAULT_INPUT_DIR)
    parser.add_argument(
        "--dict-file",
        type=Path,
        default=DEFAULT_DICT_FILE,
        help="Base dictionary used for dedup and imported-term filtering.",
    )
    parser.add_argument(
        "--output-file",
        type=Path,
        default=DEFAULT_REVIEW_FILE,
        help="Review fragment file written by default execution.",
    )
    parser.add_argument("--source", default=DEFAULT_SOURCE)
    parser.add_argument("--min-len", type=int, default=2)
    parser.add_argument("--max-len", type=int, default=8)
    parser.add_argument("--min-freq", type=int, default=2)
    parser.add_argument(
        "--min-line-freq-single-app",
        type=int,
        default=3,
        help="Require at least this many lines when a phrase only appears in one app.",
    )
    parser.add_argument("--top-n", type=int, default=50)
    parser.add_argument("--base-weight", type=int, default=120)
    parser.add_argument("--freq-weight-step", type=int, default=20)
    parser.add_argument("--app-weight-step", type=int, default=10)
    parser.add_argument("--max-weight", type=int, default=400)
    parser.add_argument(
        "--allow-existing",
        action="store_true",
        help="Include phrases already present in custom_words.dict.yaml.",
    )
    parser.add_argument(
        "--include-known-terms",
        action="store_true",
        help="Do not skip phrases that already exist in imported base dictionaries.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Preview only. Do not overwrite the review dictionary file.",
    )
    return parser.parse_args()


def load_existing_terms(dict_file: Path) -> set[str]:
    existing: set[str] = set()
    if not dict_file.exists():
        return existing
    for raw_line in dict_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line in {"---", "..."}:
            continue
        if ":" in line and "\t" not in line:
            continue
        existing.add(raw_line.split("\t", 1)[0].strip())
    return existing


def read_dict_header(dict_file: Path) -> tuple[str | None, list[str]]:
    name: str | None = None
    imports: list[str] = []
    in_header = False
    in_imports = False
    for raw_line in dict_file.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip()
        stripped = line.strip()
        if stripped == "---":
            in_header = True
            continue
        if stripped == "...":
            break
        if not in_header:
            continue
        if stripped.startswith("name:"):
            name = stripped.split(":", 1)[1].strip().strip("\"'")
            in_imports = False
            continue
        if stripped.startswith("import_tables:"):
            in_imports = True
            continue
        if in_imports:
            if stripped.startswith("- "):
                imports.append(stripped[2:].strip().strip("\"'"))
                continue
            if stripped and not stripped.startswith("#"):
                in_imports = False
    return name, imports


def resolve_dict_file(dict_name: str) -> Path | None:
    for root in DEFAULT_DICT_SEARCH_ROOTS:
        candidate = root / f"{dict_name}.dict.yaml"
        if candidate.exists():
            return candidate
    return None


def load_imported_terms(dict_file: Path) -> set[str]:
    _, imports = read_dict_header(dict_file)
    seen_dicts: set[str] = set()
    known_terms: set[str] = set()

    def visit(dict_name: str) -> None:
        if dict_name in seen_dicts:
            return
        seen_dicts.add(dict_name)
        resolved = resolve_dict_file(dict_name)
        if not resolved:
            return
        known_terms.update(load_existing_terms(resolved))
        _, nested_imports = read_dict_header(resolved)
        for nested_name in nested_imports:
            visit(nested_name)

    for imported_name in imports:
        visit(imported_name)
    return known_terms


def normalize_text(text: str) -> str:
    text = unicodedata.normalize("NFKC", text)
    text = re.sub(r"\s+", "", text)
    return text


def load_records(input_dir: Path, source_filter: str) -> list[Record]:
    records: list[Record] = []
    for jsonl_file in sorted(input_dir.glob("*.jsonl")):
        with jsonl_file.open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                payload = json.loads(line)
                if source_filter and payload.get("source") != source_filter:
                    continue
                text = normalize_text(str(payload.get("text", "")))
                if len(text) < 2:
                    continue
                records.append(
                    Record(
                        text=text,
                        app_bundle_id=str(payload.get("app_bundle_id", "")),
                    )
                )
    return records


def pos_allowed(flag: str) -> bool:
    if flag.startswith(BLOCKED_POS_PREFIXES):
        return False
    return flag.startswith(ALLOWED_POS_PREFIXES)


def token_allowed(text: str, flag: str, min_len: int, max_len: int) -> bool:
    if not HAN_TEXT_RE.fullmatch(text):
        return False
    if len(text) < min_len or len(text) > max_len:
        return False
    if is_noise(text):
        return False
    return pos_allowed(flag)


def collect_counts(
    records: list[Record], min_len: int, max_len: int
) -> tuple[Counter[str], Counter[str], dict[str, set[str]]]:
    phrase_counts: Counter[str] = Counter()
    line_counts: Counter[str] = Counter()
    apps_by_phrase: dict[str, set[str]] = defaultdict(set)

    for record in records:
        seen_in_record: set[str] = set()
        tokens = [(item.word, item.flag) for item in pseg.cut(record.text)]
        count = len(tokens)
        for start in range(count):
            for span_size in range(1, MAX_TOKEN_SPAN + 1):
                end = start + span_size
                if end > count:
                    break
                window = tokens[start:end]
                phrase = "".join(word for word, _ in window)
                if len(phrase) < min_len or len(phrase) > max_len:
                    continue
                if not HAN_TEXT_RE.fullmatch(phrase):
                    continue
                if is_noise(phrase):
                    continue
                if any(not pos_allowed(flag) for _, flag in window):
                    continue
                if not any(token_allowed(word, flag, min_len, max_len) for word, flag in window):
                    continue
                if span_size > 1 and all(len(word) == 1 for word, _ in window):
                    continue
                phrase_counts[phrase] += 1
                if phrase not in seen_in_record:
                    line_counts[phrase] += 1
                    seen_in_record.add(phrase)
                apps_by_phrase[phrase].add(record.app_bundle_id)
    return phrase_counts, line_counts, apps_by_phrase


def is_noise(phrase: str) -> bool:
    if phrase in STOP_PHRASES:
        return True
    if len(set(phrase)) == 1:
        return True
    if phrase[0] in LEADING_FUNCTION_CHARS:
        return True
    if phrase[-1] in TRAILING_FUNCTION_CHARS:
        return True
    return False


def compute_weight(
    line_freq: int,
    app_count: int,
    base_weight: int,
    freq_weight_step: int,
    app_weight_step: int,
    max_weight: int,
) -> int:
    weight = base_weight + line_freq * freq_weight_step + max(0, app_count - 1) * app_weight_step
    return min(weight, max_weight)


def build_candidates(
    records: list[Record],
    args: argparse.Namespace,
    blocked_terms: set[str],
) -> list[Candidate]:
    phrase_counts, line_counts, apps_by_phrase = collect_counts(
        records, args.min_len, args.max_len
    )

    candidates: list[Candidate] = []
    for phrase, line_freq in line_counts.items():
        if line_freq < args.min_freq:
            continue
        if not args.allow_existing and phrase in blocked_terms:
            continue
        if is_noise(phrase):
            continue
        app_count = len(apps_by_phrase[phrase])
        if app_count < 2 and line_freq < args.min_line_freq_single_app:
            continue
        candidates.append(
            Candidate(
                text=phrase,
                line_freq=line_freq,
                total_freq=phrase_counts[phrase],
                app_count=app_count,
                weight=compute_weight(
                    line_freq,
                    app_count,
                    args.base_weight,
                    args.freq_weight_step,
                    args.app_weight_step,
                    args.max_weight,
                ),
            )
        )

    candidates.sort(
        key=lambda item: (
            -len(item.text),
            -item.line_freq,
            -item.app_count,
            item.text,
        )
    )

    selected: list[Candidate] = []
    for candidate in candidates:
        if any(
            candidate.text != other.text
            and candidate.text in other.text
            and other.line_freq >= candidate.line_freq
            for other in selected
        ):
            continue
        selected.append(candidate)
        if len(selected) >= args.top_n:
            break
    return selected


def format_entries(candidates: list[Candidate]) -> list[str]:
    return [f"{candidate.text}\t\t{candidate.weight}" for candidate in candidates]


def write_review_dict(output_file: Path, candidates: list[Candidate]) -> None:
    payload = ""
    if candidates:
        payload = "\n".join(format_entries(candidates)).rstrip() + "\n"
    output_file.parent.mkdir(parents=True, exist_ok=True)
    output_file.write_text(payload, encoding="utf-8")


def print_preview(candidates: list[Candidate]) -> None:
    if not candidates:
        print("No candidates matched the current filters.")
        return
    print("text\tline_freq\ttotal_freq\tapps\tweight")
    for candidate in candidates:
        print(
            f"{candidate.text}\t{candidate.line_freq}\t{candidate.total_freq}\t"
            f"{candidate.app_count}\t{candidate.weight}"
        )


def main() -> int:
    args = parse_args()
    if args.min_len < 2:
        print("--min-len must be at least 2.", file=sys.stderr)
        return 2
    if args.max_len < args.min_len:
        print("--max-len must be >= --min-len.", file=sys.stderr)
        return 2
    if not args.input_dir.exists():
        print(f"Input directory does not exist: {args.input_dir}", file=sys.stderr)
        return 2

    records = load_records(args.input_dir, args.source)
    existing_terms = load_existing_terms(args.dict_file)
    blocked_terms = set(existing_terms)
    if not args.include_known_terms:
        blocked_terms.update(load_imported_terms(args.dict_file))
    candidates = build_candidates(records, args, blocked_terms)

    print_preview(candidates)
    if not args.dry_run and candidates:
        write_review_dict(args.output_file, candidates)
        print(f"\nWrote {len(candidates)} fragment entries to {args.output_file}")
    elif not args.dry_run:
        write_review_dict(args.output_file, [])
        print(f"\nWrote an empty review fragment to {args.output_file}")
    else:
        print("\nDry run only. Re-run without --dry-run to overwrite the review fragment file.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
