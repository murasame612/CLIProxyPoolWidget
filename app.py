#!/usr/bin/env python3
"""Lightweight web dashboard for CLIProxyAPI pool quota monitoring.

Single-file Flask app. Dependencies: flask, requests.
Usage: pip install flask requests && python app.py
"""

import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import requests
from flask import Flask, jsonify, render_template_string, request

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

CONFIG_PATH = Path(__file__).with_name("config.json")
USAGE_CACHE_PATH = Path(__file__).with_name("usage_cache.json")
DEFAULT_REFRESH_SECONDS = 30
DEFAULT_ACCOUNT_LIMIT = 8
DEFAULT_PLUS_WEIGHT = 1.0
DEFAULT_PRO_LITE_WEIGHT = 10.0
DEFAULT_PRO_WEIGHT = 20.0
DEFAULT_WEEKLY_KILL_LINE = 3.0
RECENT_REQUEST_BUCKET_COUNT = 20
MAX_CONCURRENT_USAGE_FETCHES = 4
USAGE_FETCH_RETRIES = 2
USAGE_FETCH_RETRY_DELAY_SECONDS = 0.35
RESET_AGGREGATION_SECONDS = 30 * 60
RESET_AGGREGATION_TOLERANCE = 60

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------


@dataclass
class PoolSettings:
    base_url: str = ""
    management_key: str = ""
    refresh_seconds: int = DEFAULT_REFRESH_SECONDS
    usage_account_limit: int = DEFAULT_ACCOUNT_LIMIT
    show_only_codex: bool = True
    plus_weight: float = DEFAULT_PLUS_WEIGHT
    pro_lite_weight: float = DEFAULT_PRO_LITE_WEIGHT
    pro_weight: float = DEFAULT_PRO_WEIGHT
    weekly_kill_line_percent: float = DEFAULT_WEEKLY_KILL_LINE

    @property
    def is_configured(self) -> bool:
        return bool(self.base_url.strip() and self.management_key.strip())

    def weight_for(self, plan_type: Optional[str]) -> float:
        t = PlanType.normalize(plan_type)
        if t == "pro":
            return max(0, self.pro_weight)
        if t in ("prolite", "pro_lite", "pro-lite"):
            return max(0, self.pro_lite_weight)
        return max(0, self.plus_weight)

    def to_dict(self) -> dict:
        return {
            "base_url": self.base_url,
            "management_key": self.management_key,
            "refresh_seconds": self.refresh_seconds,
            "usage_account_limit": self.usage_account_limit,
            "show_only_codex": self.show_only_codex,
            "plus_weight": self.plus_weight,
            "pro_lite_weight": self.pro_lite_weight,
            "pro_weight": self.pro_weight,
            "weekly_kill_line_percent": self.weekly_kill_line_percent,
        }

    @classmethod
    def from_dict(cls, d: dict):  # type: (...) -> PoolSettings
        return cls(
            base_url=d.get("base_url", ""),
            management_key=d.get("management_key", ""),
            refresh_seconds=d.get("refresh_seconds", DEFAULT_REFRESH_SECONDS),
            usage_account_limit=d.get("usage_account_limit", DEFAULT_ACCOUNT_LIMIT),
            show_only_codex=d.get("show_only_codex", True),
            plus_weight=d.get("plus_weight", DEFAULT_PLUS_WEIGHT),
            pro_lite_weight=d.get("pro_lite_weight", DEFAULT_PRO_LITE_WEIGHT),
            pro_weight=d.get("pro_weight", DEFAULT_PRO_WEIGHT),
            weekly_kill_line_percent=d.get("weekly_kill_line_percent", DEFAULT_WEEKLY_KILL_LINE),
        )


def load_settings() -> PoolSettings:
    """Load settings from config.json, with env var overrides for secrets."""
    s = PoolSettings()
    if CONFIG_PATH.exists():
        try:
            s = PoolSettings.from_dict(json.loads(CONFIG_PATH.read_text()))
        except (json.JSONDecodeError, KeyError):
            pass
    # Env var overrides (for secrets in production)
    env_url = os.getenv("POOL_BASE_URL")
    if env_url:
        s.base_url = env_url
    env_key = os.getenv("POOL_MANAGEMENT_KEY")
    if env_key:
        s.management_key = env_key
    return s


def save_settings(settings: PoolSettings) -> None:
    CONFIG_PATH.write_text(json.dumps(settings.to_dict(), indent=2))


def summary_to_dict(summary: "PoolSummary", refresh_seconds: int) -> Dict[str, Any]:
    return {
        "generated_at": summary.generated_at,
        "total_accounts": summary.total_accounts,
        "available_accounts": summary.available_accounts,
        "cooling_accounts": summary.cooling_accounts,
        "disabled_accounts": summary.disabled_accounts,
        "failed_recent_requests": summary.failed_recent_requests,
        "primary_remaining_units": summary.primary_remaining_units,
        "primary_capacity_units": summary.primary_capacity_units,
        "weekly_remaining_units": summary.weekly_remaining_units,
        "weekly_capacity_units": summary.weekly_capacity_units,
        "primary_remaining_percent": summary.primary_remaining_percent,
        "weekly_remaining_percent": summary.weekly_remaining_percent,
        "primary_capacity_percent": summary.primary_capacity_percent,
        "weekly_capacity_percent": summary.weekly_capacity_percent,
        "primary_bar_percent": summary.primary_bar_percent,
        "weekly_bar_percent": summary.weekly_bar_percent,
        "next_primary_reset_hint": _hint_dict(summary.next_primary_reset_hint),
        "next_weekly_reset_hint": _hint_dict(summary.next_weekly_reset_hint),
        "recent_requests": summary.recent_requests,
        "plan_breakdown": [
            {
                "plan_type": PlanType.display_name(b.plan_type),
                "count": b.count,
                "weight": b.weight,
                "primary_remaining_units": b.primary_remaining_units,
                "weekly_remaining_units": b.weekly_remaining_units,
            }
            for b in summary.plan_breakdown
        ],
        "accounts": summary.accounts,
        "error_message": summary.error_message,
        "refresh_seconds": refresh_seconds,
    }


# ---------------------------------------------------------------------------
# Plan type helpers
# ---------------------------------------------------------------------------


class PlanType:
    @staticmethod
    def normalize(value: Optional[str]) -> str:
        return (value or "plus").strip().lower()

    @staticmethod
    def display_name(value: Optional[str]) -> str:
        t = PlanType.normalize(value)
        if t == "pro":
            return "Pro"
        if t in ("prolite", "pro_lite", "pro-lite"):
            return "Pro Lite"
        return "Plus"


# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------


@dataclass
class AuthFile:
    auth_index: str
    name: Optional[str] = None
    provider: Optional[str] = None
    type: Optional[str] = None
    label: Optional[str] = None
    email: Optional[str] = None
    account: Optional[str] = None
    status: Optional[str] = None
    status_message: Optional[str] = None
    disabled: bool = False
    unavailable: bool = False
    next_retry_after: Optional[float] = None
    recent_requests: List[Dict] = field(default_factory=list)
    plan_type: Optional[str] = None
    chatgpt_account_id: Optional[str] = None

    @property
    def normalized_provider(self) -> str:
        return (self.provider or self.type or "").strip().lower()

    @property
    def display_name(self) -> str:
        for attr in [self.email, self.account, self.name, self.label]:
            if attr:
                return attr
        return self.auth_index

    @property
    def is_codex_like(self) -> bool:
        p = self.normalized_provider
        return p == "codex" or "openai" in p

    @property
    def is_available(self) -> bool:
        if self.disabled or self.unavailable:
            return False
        s = (self.status or "").lower()
        return s in ("", "active", "ok")


@dataclass
class UsageSnapshot:
    used: Optional[float] = None
    limit: Optional[float] = None
    remaining: Optional[float] = None
    used_percent: Optional[float] = None
    plan_type: Optional[str] = None
    primary_used_percent: Optional[float] = None
    primary_reset_seconds: Optional[float] = None
    primary_reset_text: Optional[str] = None
    weekly_used_percent: Optional[float] = None
    weekly_reset_seconds: Optional[float] = None
    weekly_reset_text: Optional[str] = None
    reset_text: Optional[str] = None
    raw_status: Optional[str] = None

    @property
    def has_quota_signal(self) -> bool:
        return any([
            self.used is not None,
            self.limit is not None,
            self.remaining is not None,
            self.used_percent is not None,
            self.primary_used_percent is not None,
            self.primary_reset_seconds is not None,
            self.weekly_used_percent is not None,
            self.weekly_reset_seconds is not None,
            self.plan_type is not None,
        ])

    @property
    def weekly_remaining_percent(self) -> Optional[float]:
        if self.weekly_used_percent is not None:
            return max(0, min(100, 100 - self.weekly_used_percent))
        return self.remaining

    @property
    def primary_remaining_percent(self) -> Optional[float]:
        up = self.primary_used_percent if self.primary_used_percent is not None else self.used_percent
        if up is not None:
            return max(0, min(100, 100 - up))
        return self.remaining

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)

    @classmethod
    def from_dict(cls, value: Dict[str, Any]) -> "UsageSnapshot":
        allowed = {field.name for field in cls.__dataclass_fields__.values()}
        payload = {key: value.get(key) for key in allowed if key in value}
        return cls(**payload)


@dataclass
class AccountUsage:
    auth_index: str
    name: str
    provider: str
    is_available: bool
    status_text: str
    weight: float
    weekly_kill_line_percent: float
    recent_requests: List[Dict] = field(default_factory=list)
    usage: Optional[UsageSnapshot] = None
    error: Optional[str] = None
    is_stale: bool = False

    @property
    def plan_type(self) -> Optional[str]:
        return self.usage.plan_type if self.usage else None

    def _effective_weekly_remaining(self) -> Optional[float]:
        if self.usage is None:
            return None
        wrp = self.usage.weekly_remaining_percent
        if wrp is None:
            return None
        return 0 if wrp < self.weekly_kill_line_percent else wrp

    def _effective_primary_remaining(self) -> Optional[float]:
        if self.usage is None:
            return None
        prp = self.usage.primary_remaining_percent
        if prp is None:
            return None
        wrp = self.usage.weekly_remaining_percent
        if wrp is not None and wrp < self.weekly_kill_line_percent:
            return 0
        return prp

    @property
    def weekly_weighted_remaining(self) -> float:
        if not self.is_available:
            return 0
        r = self._effective_weekly_remaining()
        return self.weight * r / 100 if r is not None else 0

    @property
    def primary_weighted_remaining(self) -> float:
        if not self.is_available:
            return 0
        r = self._effective_primary_remaining()
        return self.weight * r / 100 if r is not None else 0

    @property
    def is_week_killed(self) -> bool:
        if self.usage is None:
            return False
        wrp = self.usage.weekly_remaining_percent
        return wrp is not None and wrp < self.weekly_kill_line_percent

    @property
    def primary_reset_restored_units(self) -> float:
        if not self.is_available or self.usage is None or self.usage.primary_reset_seconds is None:
            return 0
        prp = self.usage.primary_remaining_percent
        if prp is None:
            return 0
        if self.is_week_killed:
            return 0
        return max(0, 100 - prp) * self.weight / 100

    @property
    def weekly_reset_restored_units(self) -> float:
        if not self.is_available or self.usage is None or self.usage.weekly_reset_seconds is None:
            return 0
        r = self._effective_weekly_remaining()
        if r is None:
            return 0
        return max(0, 100 - r) * self.weight / 100

    @property
    def weekly_reset_released_primary_units(self) -> float:
        if (
            not self.is_available
            or not self.is_week_killed
            or self.usage is None
            or self.usage.weekly_reset_seconds is None
        ):
            return 0
        prp = self.usage.primary_remaining_percent
        if prp is None:
            return 0
        return max(0, prp) * self.weight / 100


@dataclass
class PlanBreakdown:
    plan_type: str
    count: int
    weight: float
    primary_remaining_units: float
    weekly_remaining_units: float


@dataclass
class QuotaResetHint:
    account_count: int
    seconds_until: float
    restored_units: float
    target_units: float
    capacity_units: float

    @property
    def time_text(self) -> str:
        minutes = max(0, self.seconds_until / 60)
        if minutes < 1:
            return "<1m"
        if minutes < 60:
            return f"{int(round(minutes))}m"
        hours = minutes / 60
        if hours == int(hours):
            return f"{int(hours)}h"
        return f"{hours:.1f}h"


@dataclass
class PoolSummary:
    generated_at: float  # epoch seconds
    total_accounts: int
    available_accounts: int
    cooling_accounts: int
    disabled_accounts: int
    failed_recent_requests: int
    primary_remaining_units: float
    primary_capacity_units: float
    weekly_remaining_units: float
    weekly_capacity_units: float
    next_primary_reset_hint: Optional[QuotaResetHint]
    next_weekly_reset_hint: Optional[QuotaResetHint]
    recent_requests: List[Dict]
    plan_breakdown: List[PlanBreakdown]
    accounts: List[Dict]
    error_message: Optional[str] = None

    @property
    def weekly_remaining_percent(self) -> float:
        """Plus-base display percent (can exceed 100)."""
        return self.weekly_remaining_units * 100

    @property
    def primary_remaining_percent(self) -> float:
        """Plus-base display percent (can exceed 100)."""
        return self.primary_remaining_units * 100

    @property
    def weekly_capacity_percent(self) -> float:
        return self.weekly_capacity_units * 100

    @property
    def primary_capacity_percent(self) -> float:
        return self.primary_capacity_units * 100

    @property
    def weekly_bar_percent(self) -> float:
        """0–100 capacity-relative, for bar fill & color."""
        if self.weekly_capacity_units > 0:
            return max(0, min(100, self.weekly_remaining_units / self.weekly_capacity_units * 100))
        return 0.0

    @property
    def primary_bar_percent(self) -> float:
        """0–100 capacity-relative, for bar fill & color."""
        if self.primary_capacity_units > 0:
            return max(0, min(100, self.primary_remaining_units / self.primary_capacity_units * 100))
        return 0.0


# ---------------------------------------------------------------------------
# Usage parser
# ---------------------------------------------------------------------------


class UsageParser:
    @staticmethod
    def parse(body: str) -> UsageSnapshot:
        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            return UsageSnapshot(raw_status="invalid usage")

        pairs = UsageParser._flatten(data)
        wham = UsageParser._parse_wham(pairs)
        if wham:
            return wham

        # Fallback generic parser
        body_lower = body.lower()
        used = UsageParser._first_number(pairs, [
            "used", "usage", "consumed", "current", "count", "messages_used", "message_count"
        ])
        limit = UsageParser._first_number(pairs, [
            "limit", "total", "cap", "quota", "max", "message_limit", "messages_limit"
        ])
        remaining = UsageParser._first_number(pairs, [
            "remaining", "available", "left", "messages_remaining"
        ])
        reset = UsageParser._first_string(pairs, [
            "resets_at", "reset_at", "reset_time", "next_reset", "resets_after", "reset_after",
            "reset_after_seconds", "resetafterseconds", "retry_after", "retryafter",
            "resets_in_seconds", "reset_in_seconds", "resetsinseconds", "resetinseconds",
            "clears_in", "clearsin", "wait_seconds", "waitseconds", "renewal",
        ])
        reset_seconds = (
            UsageParser._first_number(pairs, [
                "reset_after_seconds", "resets_after_seconds", "reset_after", "resets_after",
                "resetafterseconds", "resetsafterseconds", "resetafter", "resetsafter",
                "retry_after", "retryafter", "resets_in_seconds", "reset_in_seconds",
                "resetsinseconds", "resetinseconds", "clears_in", "clearsin",
                "wait_seconds", "waitseconds",
            ])
            or UsageParser._seconds_until_epoch(
                UsageParser._first_number(pairs, [
                    "resets_at", "reset_at", "reset_time", "next_reset", "renewal",
                ])
            )
            or (UsageParser._seconds_until_reset(reset) if reset else None)
        )
        plan_type = UsageParser._first_string(pairs, ["plan_type", "plan-type", "plan"])
        status = UsageParser._first_string(pairs, ["status", "tier", "plan", "bucket", "type", "code"])
        status_lower = (status or "").lower()
        explicit_usage_limited = any(
            keyword in body_lower or keyword in status_lower
            for keyword in [
                "usage_limit_reached", "quota_limit_reached", "rate_limit_exceeded",
                "insufficient_quota", "quota exceeded", "usage limit", "limit has been reached",
            ]
        )
        has_reset_signal = reset_seconds is not None or reset is not None
        inferred_primary_used = 100.0 if explicit_usage_limited and has_reset_signal else None

        return UsageSnapshot(
            used=used,
            limit=limit,
            remaining=remaining,
            used_percent=None,
            plan_type=plan_type or (None if explicit_usage_limited else status),
            primary_used_percent=inferred_primary_used,
            primary_reset_seconds=reset_seconds,
            primary_reset_text=UsageParser._format_duration(reset_seconds) if reset_seconds else None,
            weekly_used_percent=None,
            weekly_reset_seconds=None,
            weekly_reset_text=None,
            reset_text=reset or (UsageParser._format_duration(reset_seconds) if reset_seconds else None),
            raw_status=status,
        )

    @staticmethod
    def _parse_wham(pairs: List[Tuple[str, Any]]) -> Optional[UsageSnapshot]:
        def num(path: str) -> Optional[float]:
            for p, v in pairs:
                if p == path:
                    return UsageParser._to_number(v)
            return None

        def txt(path: str) -> Optional[str]:
            for p, v in pairs:
                if p == path and isinstance(v, str) and v:
                    return v
            return None

        primary_used = num("rate_limit.primary_window.used_percent")
        secondary_used = num("rate_limit.secondary_window.used_percent")
        used_percent = primary_used if primary_used is not None else secondary_used
        primary_reset = num("rate_limit.primary_window.reset_after_seconds")
        secondary_reset = num("rate_limit.secondary_window.reset_after_seconds")
        reset_seconds = primary_reset if primary_reset is not None else secondary_reset
        plan_type = txt("plan_type") or txt("account_plan.plan_type")

        if used_percent is None and reset_seconds is None:
            return None

        return UsageSnapshot(
            used=None, limit=None, remaining=None,
            used_percent=used_percent,
            plan_type=plan_type,
            primary_used_percent=primary_used,
            primary_reset_seconds=primary_reset,
            primary_reset_text=UsageParser._format_duration(primary_reset) if primary_reset else None,
            weekly_used_percent=secondary_used,
            weekly_reset_seconds=secondary_reset,
            weekly_reset_text=UsageParser._format_duration(secondary_reset) if secondary_reset else None,
            reset_text=UsageParser._format_duration(reset_seconds) if reset_seconds else None,
            raw_status=PlanType.display_name(plan_type),
        )

    @staticmethod
    def _flatten(value: Any, path: str = "") -> List[Tuple[str, Any]]:
        if isinstance(value, dict):
            result = []
            for k, v in value.items():
                next_path = f"{path}.{k}" if path else k
                result.extend(UsageParser._flatten(v, next_path))
            return result
        if isinstance(value, list):
            result = []
            for i, v in enumerate(value):
                result.extend(UsageParser._flatten(v, f"{path}[{i}]"))
            return result
        return [(path.lower(), value)]

    @staticmethod
    def _first_number(pairs: List[Tuple[str, Any]], keys: List[str]) -> Optional[float]:
        for key in keys:
            for path, val in pairs:
                if UsageParser._path_matches(path, key):
                    n = UsageParser._to_number(val)
                    if n is not None:
                        return n
        return None

    @staticmethod
    def _first_string(pairs: List[Tuple[str, Any]], keys: List[str]) -> Optional[str]:
        for key in keys:
            for path, val in pairs:
                if UsageParser._path_matches(path, key):
                    if isinstance(val, str) and val:
                        return val
                    n = UsageParser._to_number(val)
                    if n is not None:
                        return str(int(n))
        return None

    @staticmethod
    def _path_matches(path: str, key: str) -> bool:
        cleaned = path.replace("[", ".").replace("]", "")
        components = cleaned.split(".")
        return any(c == key or c.endswith("_" + key) or c.endswith("-" + key) for c in components)

    @staticmethod
    def _to_number(val: Any) -> Optional[float]:
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            return float(val)
        if isinstance(val, str):
            try:
                return float(val.strip())
            except ValueError:
                pass
        return None

    @staticmethod
    def _format_duration(seconds: Optional[float]) -> Optional[str]:
        if seconds is None:
            return None
        total = max(0, int(round(seconds)))
        h, m = divmod(total, 3600)
        m //= 60
        if h > 0:
            return f"{h}小时{m}分钟后恢复"
        if m > 0:
            return f"{m}分钟后恢复"
        return "即将恢复"

    @staticmethod
    def _seconds_until_reset(value: str) -> Optional[float]:
        trimmed = value.strip()
        if not trimmed:
            return None
        try:
            return float(trimmed)
        except ValueError:
            pass
        # Try ISO8601 date
        try:
            from datetime import datetime as dt
            for fmt in [
                "%Y-%m-%dT%H:%M:%S.%fZ",
                "%Y-%m-%dT%H:%M:%SZ",
                "%Y-%m-%dT%H:%M:%S.%f%z",
                "%Y-%m-%dT%H:%M:%S%z",
            ]:
                try:
                    d = dt.strptime(trimmed, fmt)
                    return max(0, (d - dt.now(timezone.utc).replace(tzinfo=None)).total_seconds())
                except ValueError:
                    continue
        except Exception:
            pass
        # Parse human-readable durations
        return UsageParser._parse_duration_string(trimmed.lower())

    @staticmethod
    def _seconds_until_epoch(value: Optional[float]) -> Optional[float]:
        if value is None or value <= 0:
            return None
        if value > 10_000_000:
            value -= time.time()
        return max(0, value)

    @staticmethod
    def _parse_duration_string(text: str) -> Optional[float]:
        units = {
            "d": 86400, "day": 86400, "days": 86400,
            "h": 3600, "hour": 3600, "hours": 3600,
            "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
            "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        }
        total = 0.0
        for unit, scale in units.items():
            m = re.search(rf"(\d+(?:\.\d+)?)\s*{unit}\b", text)
            if m:
                total += float(m.group(1)) * scale
        return total if total > 0 else None


# ---------------------------------------------------------------------------
# API Client
# ---------------------------------------------------------------------------


class PoolAPIClient:
    def __init__(self, settings: PoolSettings):
        self.settings = settings
        self.session = requests.Session()
        self.session.headers.update({"User-Agent": "PoolWatchWeb/0.1"})

    def _management_url(self, path: str) -> str:
        raw = self.settings.base_url.strip().rstrip("/")
        if not raw.startswith("http"):
            raw = "https://" + raw
        path = path.strip("/")
        return f"{raw}/{path}"

    def _headers(self) -> dict:
        return {
            "Authorization": f"Bearer {self.settings.management_key.strip()}",
        }

    def fetch_auth_files(self) -> List[AuthFile]:
        url = self._management_url("/v0/management/auth-files")
        resp = self.session.get(url, headers=self._headers(), timeout=30)
        resp.raise_for_status()
        data = resp.json()
        files = []
        for f in data.get("files", data if isinstance(data, list) else []):
            id_token = f.get("id_token") or {}
            files.append(AuthFile(
                auth_index=f.get("auth_index", f.get("id", "")),
                name=f.get("name"),
                provider=f.get("provider"),
                type=f.get("type"),
                label=f.get("label"),
                email=f.get("email"),
                account=f.get("account"),
                status=f.get("status"),
                status_message=f.get("status_message"),
                disabled=f.get("disabled", False),
                unavailable=f.get("unavailable", False),
                next_retry_after=_parse_date(f.get("next_retry_after")),
                recent_requests=f.get("recent_requests", []),
                plan_type=id_token.get("plan_type"),
                chatgpt_account_id=id_token.get("chatgpt_account_id"),
            ))
        return files

    def fetch_wham_usage(self, auth_index: str, chatgpt_account_id: Optional[str] = None) -> UsageSnapshot:
        url = self._management_url("/v0/management/api-call")
        headers = self._headers()
        headers["Content-Type"] = "application/json"

        wham_headers = {
            "Authorization": "Bearer $TOKEN$",
            "Accept": "application/json",
            "Content-Type": "application/json",
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X) AppleWebKit/537.36",
        }
        if chatgpt_account_id and chatgpt_account_id.strip():
            wham_headers["ChatGPT-Account-Id"] = chatgpt_account_id.strip()

        payload = {
            "auth_index": auth_index,
            "method": "GET",
            "url": "https://chatgpt.com/backend-api/wham/usage",
            "header": wham_headers,
            "data": None,
        }
        resp = self.session.post(url, json=payload, headers=headers, timeout=30)

        snapshot = self._snapshot_from_text(resp.text)
        if snapshot is not None:
            return snapshot

        try:
            envelope = resp.json()
            if isinstance(envelope, dict):
                for key in ("body", "data", "error", "response", "result"):
                    if key in envelope:
                        snapshot = self._snapshot_from_text(_extract_body(envelope.get(key)))
                        if snapshot is not None:
                            return snapshot

                sc = _to_int(envelope.get("status_code", envelope.get("statusCode")))
                if sc is not None:
                    raise APIError(f"HTTP {sc}: {_extract_body(envelope)[:160]}")
        except json.JSONDecodeError:
            pass

        if not resp.ok:
            raise APIError(f"HTTP {resp.status_code}: {resp.text[:160]}")
        raise APIError("Invalid response from API")

    def _snapshot_from_text(self, text: str) -> Optional[UsageSnapshot]:
        if not text:
            return None

        try:
            parsed = json.loads(text)
        except json.JSONDecodeError:
            parsed = None

        if isinstance(parsed, dict):
            for key in ("body", "data", "error", "response", "result"):
                if key in parsed:
                    candidate = _extract_body(parsed.get(key))
                    nested = self._snapshot_from_text(candidate)
                    if nested is not None:
                        return nested

        snapshot = UsageParser.parse(text)
        if self._has_usable_quota_fields(snapshot):
            return snapshot
        return None

    def _has_usable_quota_fields(self, snapshot: UsageSnapshot) -> bool:
        return any([
            snapshot.used is not None,
            snapshot.limit is not None,
            snapshot.remaining is not None,
            snapshot.used_percent is not None,
            snapshot.primary_used_percent is not None,
            snapshot.primary_reset_seconds is not None,
            snapshot.weekly_used_percent is not None,
            snapshot.weekly_reset_seconds is not None,
        ])


class APIError(Exception):
    pass


def _parse_date(val: Any) -> Optional[float]:
    """Parse a date string to epoch seconds, or None."""
    if val is None:
        return None
    if isinstance(val, (int, float)):
        return float(val)
    if isinstance(val, str):
        for fmt in [
            "%Y-%m-%dT%H:%M:%S.%fZ",
            "%Y-%m-%dT%H:%M:%SZ",
            "%Y-%m-%dT%H:%M:%S.%f%z",
            "%Y-%m-%dT%H:%M:%S%z",
        ]:
            try:
                d = datetime.strptime(val, fmt)
                return d.timestamp()
            except ValueError:
                continue
    return None


def _to_int(val: Any) -> Optional[int]:
    if isinstance(val, int) and not isinstance(val, bool):
        return val
    if isinstance(val, float):
        return int(val)
    if isinstance(val, str):
        try:
            return int(val.strip())
        except ValueError:
            pass
    return None


def _extract_body(val: Any) -> str:
    if isinstance(val, str):
        return val
    if val is None:
        return ""
    return json.dumps(val) if isinstance(val, (dict, list)) else str(val)


# ---------------------------------------------------------------------------
# Summary Service
# ---------------------------------------------------------------------------


class PoolSummaryService:
    def __init__(self, client: PoolAPIClient):
        self.client = client

    def load_summary(self) -> PoolSummary:
        try:
            files = self.client.fetch_auth_files()
            visible = (
                [f for f in files if f.is_codex_like]
                if self.client.settings.show_only_codex
                else files
            )
            accounts = self._load_account_usage(visible)

            # Sort: available first, then by name
            accounts.sort(key=lambda a: (not a.is_available, a.name.lower()))

            cooling = sum(1 for f in visible if f.unavailable or f.next_retry_after is not None)
            disabled = sum(1 for f in visible if f.disabled)
            failed_recent = sum(
                sum(b.get("failed", 0) for b in f.recent_requests[-3:])
                for f in visible
            )
            recent_requests = self._merge_recent_requests(visible, RECENT_REQUEST_BUCKET_COUNT)
            active = [a for a in accounts if a.is_available]
            capacity = sum(a.weight for a in active)
            primary_remaining = sum(a.primary_weighted_remaining for a in active)
            weekly_remaining = sum(a.weekly_weighted_remaining for a in active)
            breakdown = self._plan_breakdown(active)
            primary_hint = self._reset_hint(
                self._primary_reset_events(active),
                primary_remaining,
                capacity,
            )
            weekly_hint = self._reset_hint(
                [
                    (a.usage.weekly_reset_seconds, a.weekly_reset_restored_units)
                    for a in active
                    if a.usage and a.usage.weekly_reset_seconds is not None
                ],
                weekly_remaining,
                capacity,
            )

            return PoolSummary(
                generated_at=time.time(),
                total_accounts=len(visible),
                available_accounts=sum(1 for f in visible if f.is_available),
                cooling_accounts=cooling,
                disabled_accounts=disabled,
                failed_recent_requests=failed_recent,
                primary_remaining_units=primary_remaining,
                primary_capacity_units=capacity,
                weekly_remaining_units=weekly_remaining,
                weekly_capacity_units=capacity,
                next_primary_reset_hint=primary_hint,
                next_weekly_reset_hint=weekly_hint,
                recent_requests=recent_requests,
                plan_breakdown=breakdown,
                accounts=[self._account_dict(a) for a in accounts],
                error_message=None,
            )
        except Exception as e:
            return PoolSummary(
                generated_at=time.time(),
                total_accounts=0, available_accounts=0, cooling_accounts=0,
                disabled_accounts=0, failed_recent_requests=0,
                primary_remaining_units=0, primary_capacity_units=0,
                weekly_remaining_units=0, weekly_capacity_units=0,
                next_primary_reset_hint=None, next_weekly_reset_hint=None,
                recent_requests=[],
                plan_breakdown=[], accounts=[],
                error_message=str(e),
            )

    def _load_account_usage(self, files: List[AuthFile]) -> List[AccountUsage]:
        accounts: List[AccountUsage] = []
        batch_size = max(1, MAX_CONCURRENT_USAGE_FETCHES)

        for start in range(0, len(files), batch_size):
            batch = files[start:start + batch_size]
            with ThreadPoolExecutor(max_workers=min(batch_size, len(batch) or 1)) as pool:
                futures = [pool.submit(self._usage_for, f) for f in batch]
                for future in as_completed(futures):
                    accounts.append(future.result())

        accounts.sort(key=lambda a: (not a.is_available, a.name.lower()))
        return accounts

    def _merge_recent_requests(self, files: List[AuthFile], limit: int) -> List[Dict]:
        if limit <= 0:
            return []

        merged = [{"success": 0, "failed": 0} for _ in range(limit)]
        for file in files:
            buckets = file.recent_requests[-limit:]
            offset = limit - len(buckets)
            for index, bucket in enumerate(buckets):
                target = offset + index
                merged[target] = {
                    "time": bucket.get("time", merged[target].get("time")),
                    "success": merged[target].get("success", 0) + int(bucket.get("success", 0) or 0),
                    "failed": merged[target].get("failed", 0) + int(bucket.get("failed", 0) or 0),
                }
        return merged

    def _primary_reset_events(self, accounts: List[AccountUsage]) -> List[Tuple[float, float]]:
        events: List[Tuple[float, float]] = []
        for account in accounts:
            if account.usage is None:
                continue
            if account.usage.primary_reset_seconds is not None:
                events.append((account.usage.primary_reset_seconds, account.primary_reset_restored_units))
            if account.usage.weekly_reset_seconds is not None:
                events.append((account.usage.weekly_reset_seconds, account.weekly_reset_released_primary_units))
        return events

    def _usage_for(self, file: AuthFile) -> AccountUsage:
        try:
            snap = self.client.fetch_wham_usage(file.auth_index, file.chatgpt_account_id)
            if snap.plan_type is None:
                snap.plan_type = file.plan_type
            return AccountUsage(
                auth_index=file.auth_index,
                name=file.display_name,
                provider=file.normalized_provider,
                is_available=self._is_quota_available(file, snap),
                status_text=self._status_text(file, snap),
                weight=self.client.settings.weight_for(snap.plan_type),
                weekly_kill_line_percent=self.client.settings.weekly_kill_line_percent,
                recent_requests=file.recent_requests[-RECENT_REQUEST_BUCKET_COUNT:],
                usage=snap,
                error=None,
            )
        except Exception as e:
            fallback = self._snapshot_from_error(e)
            if fallback is not None:
                if fallback.plan_type is None:
                    fallback.plan_type = file.plan_type
                return AccountUsage(
                    auth_index=file.auth_index,
                    name=file.display_name,
                    provider=file.normalized_provider,
                    is_available=self._is_quota_available(file, fallback),
                    status_text=self._status_text(file, fallback),
                    weight=self.client.settings.weight_for(fallback.plan_type),
                    weekly_kill_line_percent=self.client.settings.weekly_kill_line_percent,
                    recent_requests=file.recent_requests[-RECENT_REQUEST_BUCKET_COUNT:],
                    usage=fallback,
                    error=None,
                )
            return AccountUsage(
                auth_index=file.auth_index,
                name=file.display_name,
                provider=file.normalized_provider,
                is_available=file.is_available,
                status_text=self._status_text(file),
                weight=self.client.settings.weight_for(file.plan_type),
                weekly_kill_line_percent=self.client.settings.weekly_kill_line_percent,
                recent_requests=file.recent_requests[-RECENT_REQUEST_BUCKET_COUNT:],
                usage=None,
                error=str(e),
            )

    def _snapshot_from_error(self, error: Exception) -> Optional[UsageSnapshot]:
        text = str(error)
        match = re.search(r"(\{.*\})", text)
        if match is None:
            return None
        return self.client._snapshot_from_text(match.group(1))

    def _is_quota_available(self, file: AuthFile, usage: UsageSnapshot) -> bool:
        if file.disabled:
            return False
        if usage.has_quota_signal:
            return True
        return file.is_available

    def _status_text(self, file: AuthFile, usage: Optional[UsageSnapshot] = None) -> str:
        if usage and usage.has_quota_signal and (file.unavailable or not file.is_available):
            if self._is_primary_quota_limited(usage):
                return "额度受限"
            return "可用"
        if file.disabled:
            return "已禁用"
        if file.unavailable:
            if file.next_retry_after:
                t = datetime.fromtimestamp(file.next_retry_after).strftime("%H:%M")
                return f"冷却中，至 {t}"
            return "冷却中"
        if file.status_message:
            return file.status_message
        if file.status:
            return file.status
        return "可用" if file.is_available else "未知"

    def _is_primary_quota_limited(self, usage: UsageSnapshot) -> bool:
        remaining = usage.primary_remaining_percent
        return remaining is not None and remaining <= 0.05

    def _plan_breakdown(self, accounts: List[AccountUsage]) -> List[PlanBreakdown]:
        groups: Dict[str, List[AccountUsage]] = {}
        for a in accounts:
            pt = PlanType.normalize(a.plan_type)
            groups.setdefault(pt, []).append(a)
        result = [
            PlanBreakdown(
                plan_type=pt,
                count=len(accs),
                weight=accs[0].weight,
                primary_remaining_units=sum(a.primary_weighted_remaining for a in accs),
                weekly_remaining_units=sum(a.weekly_weighted_remaining for a in accs),
            )
            for pt, accs in groups.items()
        ]
        result.sort(key=lambda b: (-b.weight, b.plan_type))
        return result


    def _reset_hint(
        self,
        events: List[Tuple[float, float]],
        current_units: float,
        capacity_units: float,
    ) -> Optional[QuotaResetHint]:
        filtered = [(s, u) for s, u in events if s >= 0 and u > 0.0001]
        if not filtered:
            return None
        filtered.sort(key=lambda x: x[0])
        first_s, _ = filtered[0]
        bucket_end = first_s + RESET_AGGREGATION_SECONDS + RESET_AGGREGATION_TOLERANCE
        bucket = [(s, u) for s, u in filtered if s <= bucket_end]
        restored = sum(u for _, u in bucket)
        if restored <= 0:
            return None
        latest_s = max(s for s, _ in bucket)
        return QuotaResetHint(
            account_count=len(bucket),
            seconds_until=latest_s,
            restored_units=restored,
            target_units=min(capacity_units, current_units + restored),
            capacity_units=capacity_units,
        )

    def _account_dict(self, a: AccountUsage) -> dict:
        u = a.usage
        return {
            "auth_index": a.auth_index,
            "name": a.name,
            "provider": a.provider,
            "is_available": a.is_available,
            "status_text": a.status_text,
            "weight": a.weight,
            "plan_type": PlanType.display_name(a.plan_type),
            "is_week_killed": a.is_week_killed,
            "recent_requests": a.recent_requests,
            "primary_weighted_remaining": a.primary_weighted_remaining,
            "weekly_weighted_remaining": a.weekly_weighted_remaining,
            "primary_remaining_percent": u.primary_remaining_percent if u else None,
            "weekly_remaining_percent": u.weekly_remaining_percent if u else None,
            "primary_reset_text": u.primary_reset_text if u else None,
            "weekly_reset_text": u.weekly_reset_text if u else None,
            "has_quota_signal": u.has_quota_signal if u else False,
            "error": a.error,
        }

# ---------------------------------------------------------------------------
# Flask app
# ---------------------------------------------------------------------------

app = Flask(__name__)

HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>额度面板</title>
<style>
:root {
  --bg: #f8f9fa;
  --card: #fff;
  --border: #dee2e6;
  --text: #212529;
  --muted: #6c757d;
  --red: #dc3545;
  --yellow: #fd7e14;
  --green: #198754;
  --blue: #0d6efd;
  --radius: 8px;
}
* { box-sizing:border-box; margin:0; padding:0; }
body { font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif; background:var(--bg); color:var(--text); line-height:1.5; padding:16px; }
h2 { font-size:1.1rem; margin-bottom:8px; }
h3 { font-size:0.95rem; margin-bottom:6px; }

/* Settings */
.settings { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:16px; margin-bottom:16px; }
.settings summary { cursor:pointer; font-weight:600; }
.settings form { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-top:12px; }
.settings label { font-size:0.85rem; color:var(--muted); display:block; }
.settings input,.settings select { width:100%; padding:6px 8px; border:1px solid var(--border); border-radius:4px; font-size:0.9rem; }
.settings .full { grid-column:1/-1; }
.settings .actions { display:flex; gap:8px; margin-top:8px; }
.settings .actions button { padding:6px 16px; border:1px solid var(--border); border-radius:4px; background:var(--blue); color:#fff; cursor:pointer; font-size:0.9rem; }
.settings .actions button.secondary { background:var(--bg); color:var(--text); }

.summary { max-width:1120px; margin:0 auto; }
.overview-title { display:flex; justify-content:space-between; align-items:baseline; margin:6px 0 14px; }
.overview-title h1 { font-size:1.35rem; font-weight:750; letter-spacing:0; }
.overview-title span { color:var(--muted); font-size:0.82rem; }

/* Cards row */
.cards { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:12px; margin-bottom:14px; }
.card { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:14px; min-height:92px; }
.card .icon { font-size:1.1rem; margin-bottom:8px; }
.card .num { font-size:1.55rem; font-weight:750; line-height:1.1; }
.card .lbl { font-size:0.78rem; color:var(--muted); margin-top:4px; }
.card.warn .num { color:var(--yellow); }
.card.bad .num { color:var(--red); }

/* Progress bars */
.bar-stack { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:16px; margin-bottom:14px; }
.bar-section { margin-bottom:12px; }
.bar-section:last-child { margin-bottom:0; }
.bar-header { display:flex; justify-content:space-between; align-items:baseline; margin-bottom:6px; }
.bar-header .label { font-weight:600; }
.bar-header .value { font-size:0.9rem; color:var(--muted); font-variant-numeric:tabular-nums; }
.bar-track { height:18px; background:#e9ecef; border-radius:99px; overflow:hidden; position:relative; }
.bar-fill { height:100%; border-radius:99px; transition:width 0.4s; position:absolute; left:0; top:0; }
.bar-fill.green { background:var(--green); }
.bar-fill.yellow { background:var(--yellow); }
.bar-fill.red { background:var(--red); }
.bar-restore { position:absolute; top:0; height:100%; opacity:0.46; border-radius:99px; pointer-events:none; }
.bar-restore.primary { background:#38bdf8; }
.bar-restore.weekly { background:#a78bfa; }
.reset-hint { font-size:0.76rem; color:var(--muted); margin-top:4px; font-weight:700; font-variant-numeric:tabular-nums; }
.reset-hint.primary { color:#0284c7; }
.reset-hint.weekly { color:#7c3aed; }

/* Health */
.health-card { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:13px 14px; margin-bottom:14px; display:grid; grid-template-columns:92px minmax(180px,1fr) 92px; align-items:center; gap:12px; }
.health-label { font-weight:700; color:var(--muted); font-size:0.92rem; }
.health-failed { text-align:right; font-variant-numeric:tabular-nums; }
.health-failed strong { display:block; font-size:1rem; }
.health-failed strong.bad { color:var(--red); }
.health-failed span { display:block; color:var(--muted); font-size:0.7rem; }
.health-timeline { display:flex; align-items:center; justify-content:center; gap:3px; min-width:0; }
.health-pill { flex:0 1 22px; min-width:4px; max-width:28px; height:10px; border-radius:99px; background:rgba(108,117,125,.22); }
.health-pill.small { max-width:12px; height:7px; }
.health-pill.ok { background:var(--green); }
.health-pill.fail { background:var(--red); }
.health-pill.mixed { background:#ffc107; }

/* Account list */
.account-panel { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:12px 14px; margin-bottom:12px; }
.account-toolbar { display:flex; justify-content:space-between; align-items:center; gap:12px; margin-bottom:8px; }
.account-toolbar h3 { margin:0; font-size:0.95rem; }
.sort-controls { display:flex; gap:6px; align-items:center; }
.segmented { display:inline-flex; overflow:hidden; border:1px solid var(--border); border-radius:7px; background:#f1f3f5; }
.segmented button, .sort-dir { border:0; background:transparent; padding:5px 10px; font-size:.78rem; cursor:pointer; color:var(--muted); }
.segmented button.active { background:var(--card); color:var(--text); font-weight:700; box-shadow:0 0 0 1px rgba(0,0,0,.04); }
.sort-dir { border:1px solid var(--border); border-radius:7px; background:var(--card); min-width:30px; }
.account-list { display:flex; flex-direction:column; }
.account-row { min-height:66px; display:grid; grid-template-columns:minmax(160px,1fr) minmax(130px,240px) minmax(190px,1fr); align-items:center; gap:14px; border-top:1px solid var(--border); padding:7px 0; }
.account-row:first-child { border-top:0; }
.account-left { min-width:0; display:flex; align-items:center; gap:12px; }
.status-dot { width:9px; height:9px; border-radius:99px; flex:0 0 auto; background:var(--green); }
.status-dot.cool { background:var(--yellow); }
.account-name-line { min-width:0; display:flex; align-items:center; gap:8px; }
.account-name { font-weight:700; overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.account-status { font-size:0.76rem; color:var(--muted); overflow:hidden; text-overflow:ellipsis; white-space:nowrap; }
.account-health { justify-self:center; width:100%; max-width:240px; }
.account-right { justify-self:end; width:220px; }
.usage-line { display:grid; grid-template-columns:32px 90px 76px; align-items:center; gap:7px; margin:2px 0; font-size:0.75rem; }
.usage-label { font-weight:700; color:var(--muted); }
.usage-text { text-align:right; font-variant-numeric:tabular-nums; }
.usage-reset { text-align:right; color:var(--muted); font-size:.7rem; margin-top:1px; white-space:nowrap; }
.badge { display:inline-flex; align-items:center; gap:4px; padding:2px 7px; border-radius:99px; font-size:0.68rem; font-weight:750; white-space:nowrap; border:1px solid transparent; }
.badge.pro { background:rgba(255,184,45,.18); color:#b77900; border-color:rgba(255,184,45,.38); box-shadow:0 0 10px rgba(255,184,45,.38); }
.badge.prolite { background:rgba(239,151,40,.16); color:#a35a00; border-color:rgba(239,151,40,.34); }
.badge.plus { background:rgba(13,110,253,.13); color:var(--blue); border-color:rgba(13,110,253,.28); }
.badge.killed { background:#f8d7da; color:var(--red); border-color:#f1aeb5; }
.mini-bar { height:7px; background:#e9ecef; border-radius:99px; overflow:hidden; }
.mini-bar-fill { height:100%; border-radius:99px; }
.mini-bar-fill.green { background:var(--green); }
.mini-bar-fill.yellow { background:var(--yellow); }
.mini-bar-fill.red { background:var(--red); }
.mini-bar-fill.muted { background:rgba(108,117,125,.45); }
.muted { color:var(--muted); }

/* Breakdown */
.breakdown { background:var(--card); border:1px solid var(--border); border-radius:var(--radius); padding:16px; margin-bottom:12px; }
.breakdown .row { display:flex; justify-content:space-between; align-items:center; padding:4px 0; font-size:0.9rem; }
.breakdown .row+.row { border-top:1px solid var(--border); }

/* Error */
.error { background:#f8d7da; color:var(--red); border:1px solid #f5c2c7; border-radius:var(--radius); padding:12px 16px; margin-bottom:12px; }
.warning { background:#fff3cd; color:#997404; border:1px solid #ffe69c; border-radius:var(--radius); padding:10px 14px; margin-bottom:12px; font-size:0.86rem; }

/* Footer */
.footer { text-align:center; font-size:0.8rem; color:var(--muted); margin-top:8px; }
.spinner { display:inline-block; animation:spin 1s linear infinite; }
@keyframes spin { to { transform:rotate(360deg); } }

@media(max-width:600px) {
  .settings form { grid-template-columns:1fr; }
  .cards { grid-template-columns:1fr; }
  .health-card { grid-template-columns:1fr; gap:8px; }
  .health-label,.health-failed { text-align:left; }
  .account-toolbar { align-items:flex-start; flex-direction:column; }
  .account-row { grid-template-columns:1fr; gap:8px; }
  .account-health { justify-self:stretch; max-width:none; }
  .account-right { justify-self:stretch; width:100%; }
}
</style>
</head>
<body>

<details class="settings" {{ 'open' if not configured else '' }}>
  <summary>设置</summary>
  <form id="settings-form">
    <div>
      <label>Pool 地址</label>
      <input name="base_url" value="{{ settings.base_url }}" placeholder="https://pool.example.com">
    </div>
    <div>
      <label>管理 Key</label>
      <input name="management_key" value="{{ settings.management_key }}" type="password" placeholder="sk-...">
    </div>
    <div>
      <label>刷新间隔（秒）</label>
      <input name="refresh_seconds" value="{{ settings.refresh_seconds }}" type="number" min="5">
    </div>
    <div>
      <label>显示账号数</label>
      <input name="usage_account_limit" value="{{ settings.usage_account_limit }}" type="number" min="1" max="50">
    </div>
    <div>
      <label>Plus 倍率</label>
      <input name="plus_weight" value="{{ settings.plus_weight }}" type="number" step="0.1" min="0">
    </div>
    <div>
      <label>Pro Lite 倍率</label>
      <input name="pro_lite_weight" value="{{ settings.pro_lite_weight }}" type="number" step="0.1" min="0">
    </div>
    <div>
      <label>Pro 倍率</label>
      <input name="pro_weight" value="{{ settings.pro_weight }}" type="number" step="0.1" min="0">
    </div>
    <div>
      <label>周额度斩杀线 %</label>
      <input name="weekly_kill_line_percent" value="{{ settings.weekly_kill_line_percent }}" type="number" step="0.1" min="0" max="100">
    </div>
    <div>
      <label>仅显示 Codex</label>
      <select name="show_only_codex">
        <option value="1" {{ 'selected' if settings.show_only_codex else '' }}>是</option>
        <option value="0" {{ '' if settings.show_only_codex else 'selected' }}>否</option>
      </select>
    </div>
    <div class="full actions">
      <button type="button" onclick="saveSettings()">保存并刷新</button>
      <button type="button" class="secondary" onclick="doRefresh()">立即刷新</button>
      <span id="timer" style="font-size:0.85rem;color:var(--muted);align-self:center;"></span>
    </div>
  </form>
</details>

<div id="content">
  <div style="text-align:center;padding:60px 0;color:var(--muted);">
    <p>先填写 Pool 地址和管理 Key，然后点击<strong>保存并刷新</strong>。</p>
  </div>
</div>

<script>
let countdown = 0;
let interval = null;
let sortMode = localStorage.getItem('poolwatch.sortMode') || 'fiveHour';
let sortDescending = (localStorage.getItem('poolwatch.sortDescending') || '1') === '1';
const isConfigured = {{ 'true' if configured else 'false' }};
let lastErrorMessage = '';

function saveSettings() {
  const form = document.getElementById('settings-form');
  const data = Object.fromEntries(new FormData(form));
  data.show_only_codex = data.show_only_codex === '1';
  data.refresh_seconds = parseInt(data.refresh_seconds);
  data.usage_account_limit = parseInt(data.usage_account_limit);
  data.plus_weight = parseFloat(data.plus_weight);
  data.pro_lite_weight = parseFloat(data.pro_lite_weight);
  data.pro_weight = parseFloat(data.pro_weight);
  data.weekly_kill_line_percent = parseFloat(data.weekly_kill_line_percent);

  fetch('/api/settings', {
    method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify(data)
  }).then(r => r.json()).then(d => {
    if(d.ok) doRefresh();
  });
}

let lastData = null;

function doRefresh() {
  fetch('/api/summary').then(r => r.json()).then(data => {
    if(data.error_message) {
      lastErrorMessage = data.error_message;
      if(lastData) {
        document.getElementById('content').innerHTML = renderSummary(lastData, lastErrorMessage);
      } else {
        document.getElementById('content').innerHTML = renderError(data.error_message);
      }
    } else {
      lastErrorMessage = '';
      lastData = data;
      document.getElementById('content').innerHTML = renderSummary(data);
    }
    countdown = data.refresh_seconds || 30;
    updateTimer();
    clearInterval(interval);
    interval = setInterval(tick, 1000);
  }).catch(e => {
    lastErrorMessage = e.message;
    if(lastData) {
      document.getElementById('content').innerHTML = renderSummary(lastData, lastErrorMessage);
    } else {
      document.getElementById('content').innerHTML = renderError(e.message);
    }
  });
}

function tick() {
  countdown--;
  updateTimer();
  if(countdown <= 0) doRefresh();
}

function updateTimer() {
  document.getElementById('timer').textContent = countdown + ' 秒后自动刷新';
}

function barColor(pct) {
  if(pct === null || pct === undefined) return 'green';
  if(pct > 70) return 'green';
  if(pct > 20) return 'yellow';
  return 'red';
}

function fmt(v) {
  if(v === null || v === undefined) return '?';
  return Number.isInteger(v) ? v : v.toFixed(1);
}

function planBadge(pt) {
  const map = {pro:'pro',prolite:'prolite',plus:'plus'};
  const norm = (pt||'').toLowerCase().replace(/[ _-]/g,'');
  const cls = map[norm] || 'plus';
  return '<span class="badge '+cls+'">'+pt+'</span>';
}

function renderError(msg) {
  return '<div class="error">'+msg+'</div>';
}

function renderSummary(d, warningMessage) {
  const wbp = d.weekly_bar_percent;    // 0–100 for bar fill
  const pbp = d.primary_bar_percent;
  const wp = d.weekly_remaining_percent;
  const pp = d.primary_remaining_percent;
  const wcp = d.weekly_capacity_percent;
  const pcp = d.primary_capacity_percent;
  const wHint = d.next_weekly_reset_hint;
  const pHint = d.next_primary_reset_hint;

  let html = '<div class="summary">';
  html += '<div class="overview-title"><h1>概览</h1><span>更新时间 ' + new Date(d.generated_at*1000).toLocaleTimeString() + '</span></div>';
  if(warningMessage) html += '<div class="warning">刷新失败，当前保留上一次成功数据。' + esc(shortError(warningMessage)) + '</div>';

  html += '<div class="cards">';
  html += card('可用账号', d.available_accounts + '/' + d.total_accounts, '✓', (d.available_accounts===0 && d.total_accounts>0)?'bad':'');
  html += card('冷却中', d.cooling_accounts, '◷', d.cooling_accounts>0?'warn':'');
  html += card('近期失败', d.failed_recent_requests, '×', d.failed_recent_requests>0?'bad':'');
  html += '</div>';

  html += '<div class="bar-stack">';
  html += '<div class="bar-section" id="primary-bar-section">';
  html += '<div class="bar-header"><span class="label">5h</span><span class="value" id="primary-bar-text">'+fmt(pp)+'% / '+fmt(pcp)+'%</span></div>';
  html += renderBigBar(pbp, pHint, d.primary_capacity_units, 'primary');
  if(pHint) html += '<div class="reset-hint primary">'+pHint.account_count+' 个账号恢复 +' + fmt(pHint.restored_units*100) + '%，' + pHint.time_text + '</div>';
  html += '</div>';
  html += '<div class="bar-section" id="weekly-bar-section">';
  html += '<div class="bar-header"><span class="label">周额度</span><span class="value" id="weekly-bar-text">'+fmt(wp)+'% / '+fmt(wcp)+'%</span></div>';
  html += renderBigBar(wbp, wHint, d.weekly_capacity_units, 'weekly');
  if(wHint) html += '<div class="reset-hint weekly">'+wHint.account_count+' 个账号恢复 +' + fmt(wHint.restored_units*100) + '%，' + wHint.time_text + '</div>';
  html += '</div></div>';

  html += renderHealthOverview(d.recent_requests || []);

  html += '<div class="account-panel">';
  html += '<div class="account-toolbar"><h3>账号</h3>';
  html += '<div class="sort-controls"><div class="segmented">';
  html += sortButton('fiveHour', '5h') + sortButton('week', '周额度') + sortButton('name', '名称');
  html += '</div><button class="sort-dir" onclick="toggleSortDir()" title="切换排序方向">'+(sortDescending ? '↓' : '↑')+'</button></div></div>';
  html += '<div class="account-list">';
  const accounts = sortedAccounts(d.accounts || []).slice(0, Math.max(1, d.usage_account_limit || 8));
  for(const a of accounts) html += renderAccountRow(a);
  html += '</div></div>';

  if(d.plan_breakdown && d.plan_breakdown.length>0) {
    html += '<div class="breakdown"><h3>订阅构成</h3>';
    for(const b of d.plan_breakdown) {
      const ppct = b.primary_remaining_units * 100;
      const wpct = b.weekly_remaining_units * 100;
      html += '<div class="row"><span>'+planBadge(b.plan_type)+' <b>x'+b.count+'</b>（倍率 '+fmt(b.weight)+'）</span>';
      html += '<span><span style="color:#0d6efd">5h '+fmt(ppct)+'%</span> &nbsp; <span style="color:#6f42c1">周 '+fmt(wpct)+'%</span></span></div>';
    }
    html += '</div>';
  }

  html += '<div class="footer">当前显示 ' + Math.min((d.accounts||[]).length, Math.max(1, d.usage_account_limit || 8)) + ' / ' + (d.accounts||[]).length + ' 个已计算账号</div>';
  html += '</div>';
  return html;
}

function card(label, num, icon, cls) {
  return '<div class="card '+cls+'"><div class="icon">'+icon+'</div><div class="num">'+num+'</div><div class="lbl">'+label+'</div></div>';
}

function renderBigBar(pct, hint, capacity, kind) {
  const col = barColor(pct);
  const w = Math.max(0,Math.min(100,pct||0));
  let html = '<div class="bar-track">';
  html += '<div class="bar-fill '+col+'" style="width:'+w+'%"></div>';
  if(hint && hint.target_units > 0 && capacity > 0) {
    const target = Math.min(100, hint.target_units / capacity * 100);
    const diff = target - w;
    if(diff > 0.5) {
      html += '<div class="bar-restore '+kind+'" style="left:'+w+'%;width:'+diff+'%"></div>';
    }
  }
  html += '</div>';
  return html;
}

function renderMiniBar(pct, muted) {
  const col = muted ? 'muted' : barColor(pct);
  const w = Math.max(0,Math.min(100,pct||0));
  return '<div class="mini-bar"><div class="mini-bar-fill '+col+'" style="width:'+w+'%"></div></div>';
}

function renderHealthOverview(buckets) {
  const failed = buckets.reduce((sum, b) => sum + Number(b.failed || 0), 0);
  return '<div class="health-card"><div class="health-label">⌁ 健康度</div>'
    + '<div class="health-timeline">' + renderHealthPills(buckets, false) + '</div>'
    + '<div class="health-failed"><strong class="'+(failed > 0 ? 'bad' : '')+'">'+failed+'</strong><span>失败</span></div></div>';
}

function renderHealthPills(buckets, small) {
  const latest = (buckets || []).slice(-20);
  const padded = Array(Math.max(0, 20 - latest.length)).fill({success:0, failed:0}).concat(latest);
  return padded.map(b => '<span class="health-pill '+(small ? 'small ' : '')+healthClass(b)+'"></span>').join('');
}

function healthClass(b) {
  const success = Number(b.success || 0);
  const failed = Number(b.failed || 0);
  if(success > 0 && failed > 0) return 'mixed';
  if(failed > 0) return 'fail';
  if(success > 0) return 'ok';
  return '';
}

function renderAccountRow(a) {
  const pr = a.primary_remaining_percent;
  const wr = a.weekly_remaining_percent;
  const primaryText = a.is_week_killed ? 'weekKILL' : fmt(pr) + '%';
  const primaryMuted = !!a.is_week_killed;
  let html = '<div class="account-row">';
  html += '<div class="account-left"><span class="status-dot '+(a.is_available ? '' : 'cool')+'"></span><div style="min-width:0">';
  html += '<div class="account-name-line"><span class="account-name">'+esc(a.name)+'</span>'+planBadge(a.plan_type)+(a.is_week_killed?' <span class="badge killed">KILL</span>':'')+'</div>';
  html += '<div class="account-status">'+esc(a.status_text || '')+(a.error?' · 请求失败':'')+'</div></div></div>';
  html += '<div class="account-health"><div class="health-timeline">'+renderHealthPills(a.recent_requests || [], true)+'</div></div>';
  html += '<div class="account-right">';
  html += usageLine('5h', pr, primaryText, primaryMuted);
  html += usageLine('周', wr, fmt(wr)+'%', false);
  if(a.primary_reset_text && a.weekly_reset_text) html += '<div class="usage-reset">5h ' + esc(a.primary_reset_text) + ' · 周 ' + esc(a.weekly_reset_text) + '</div>';
  html += '</div></div>';
  return html;
}

function usageLine(label, pct, text, muted) {
  return '<div class="usage-line"><span class="usage-label">'+label+'</span>'+renderMiniBar(pct, muted)+'<span class="usage-text '+(muted?'muted':'')+'" style="color:'+(muted?'':'')+'">'+esc(text)+'</span></div>';
}

function sortButton(mode, label) {
  return '<button class="'+(sortMode === mode ? 'active' : '')+'" onclick="setSortMode(\''+mode+'\')">'+label+'</button>';
}

function setSortMode(mode) {
  if(sortMode === mode) {
    sortDescending = !sortDescending;
  } else {
    sortMode = mode;
  }
  localStorage.setItem('poolwatch.sortMode', sortMode);
  localStorage.setItem('poolwatch.sortDescending', sortDescending ? '1' : '0');
  if(lastData) document.getElementById('content').innerHTML = renderSummary(lastData, lastErrorMessage);
}

function toggleSortDir() {
  sortDescending = !sortDescending;
  localStorage.setItem('poolwatch.sortDescending', sortDescending ? '1' : '0');
  if(lastData) document.getElementById('content').innerHTML = renderSummary(lastData, lastErrorMessage);
}

function sortedAccounts(accounts) {
  const arr = accounts.slice();
  arr.sort((a, b) => {
    let av, bv;
    if(sortMode === 'name') {
      const cmp = String(a.name || '').localeCompare(String(b.name || ''), undefined, {sensitivity:'base'});
      return sortDescending ? -cmp : cmp;
    }
    if(sortMode === 'week') {
      av = Number(a.weekly_weighted_remaining || 0);
      bv = Number(b.weekly_weighted_remaining || 0);
    } else {
      av = Number(a.primary_weighted_remaining || 0);
      bv = Number(b.primary_weighted_remaining || 0);
    }
    if(av === bv) return String(a.name || '').localeCompare(String(b.name || ''), undefined, {sensitivity:'base'});
    return sortDescending ? bv - av : av - bv;
  });
  return arr;
}

function esc(v) {
  return String(v ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
}

function shortError(message) {
  const text = String(message || '').replace(/\s+/g, ' ').trim();
  if(text.length <= 160) return text;
  return text.slice(0, 157) + '...';
}

if(isConfigured) doRefresh();
</script>
</body>
</html>"""


@app.route("/")
def index():
    settings = load_settings()
    return render_template_string(
        HTML_TEMPLATE,
        settings=settings,
        configured=settings.is_configured,
    )


@app.route("/api/settings", methods=["POST"])
def api_settings():
    data = request.get_json()
    s = PoolSettings.from_dict(data)
    save_settings(s)
    return jsonify({"ok": True})


@app.route("/api/summary")
def api_summary():
    settings = load_settings()
    if not settings.is_configured:
        return jsonify({"error_message": "需要填写 Pool 地址和管理 Key。", "accounts": []})
    client = PoolAPIClient(settings)
    service = PoolSummaryService(client)
    summary = service.load_summary()
    result = summary_to_dict(summary, settings.refresh_seconds)
    result["usage_account_limit"] = settings.usage_account_limit
    return jsonify(result)


def _hint_dict(hint: Optional[QuotaResetHint]) -> Optional[Dict]:
    if hint is None:
        return None
    return {
        "account_count": hint.account_count,
        "seconds_until": hint.seconds_until,
        "restored_units": hint.restored_units,
        "target_units": hint.target_units,
        "capacity_units": hint.capacity_units,
        "time_text": hint.time_text,
    }


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    port = int(os.getenv("PORT", "2225"))
    debug = os.getenv("DEBUG", "").lower() in ("1", "true", "yes")
    print(f"Pool Watch web server → http://0.0.0.0:{port}")
    app.run(host="0.0.0.0", port=port, debug=debug)
