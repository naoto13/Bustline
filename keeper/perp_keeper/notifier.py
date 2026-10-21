"""Telegram notifier (adapted from bot_list shared/notifications/telegram.py, stdlib-only).

Token/chat come from env (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID / TELEGRAM_MESSAGE_THREAD_ID).
Without a token — or with dry_run=True — messages are printed instead of sent.
The token is never logged.
"""

from __future__ import annotations

import json
import os
import time
import urllib.request
from dataclasses import dataclass, field
from typing import Callable, Optional

LEVEL_ICON = {"info": "🟢", "warning": "🟡", "critical": "🔴"}


@dataclass
class TelegramNotifier:
    bot_token: Optional[str] = None
    chat_id: Optional[str] = None
    message_thread_id: Optional[int] = None
    dry_run: bool = False
    bot_name: str = "Bustline keeper"
    retry_attempts: int = 3
    retry_base_delay: float = 1.0
    printer: Callable[[str], None] = print
    sent: list[str] = field(default_factory=list)  # for tests / demo logs

    BASE_URL = "https://api.telegram.org/bot"

    @classmethod
    def from_env(cls, dry_run: bool = False, **kw) -> "TelegramNotifier":
        thread = os.getenv("TELEGRAM_MESSAGE_THREAD_ID")
        return cls(
            bot_token=os.getenv("TELEGRAM_BOT_TOKEN") or None,
            chat_id=os.getenv("TELEGRAM_CHAT_ID") or None,
            message_thread_id=int(thread) if thread else None,
            dry_run=dry_run,
            **kw,
        )

    @property
    def live(self) -> bool:
        return bool(self.bot_token and self.chat_id and not self.dry_run)

    def notify(self, level: str, title: str, body: str = "") -> None:
        text = f"{LEVEL_ICON.get(level, 'ℹ️')} [{self.bot_name}] {title}"
        if body:
            text += f"\n{body}"
        self.sent.append(text)
        if not self.live:
            self.printer(f"[telegram dry-run] {text}")
            return
        self._send(text)

    def _send(self, text: str) -> None:
        payload = {"chat_id": self.chat_id, "text": text, "disable_web_page_preview": True}
        if self.message_thread_id is not None:
            payload["message_thread_id"] = self.message_thread_id
        req = urllib.request.Request(
            f"{self.BASE_URL}{self.bot_token}/sendMessage",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        last: Optional[Exception] = None
        for attempt in range(self.retry_attempts):
            try:
                with urllib.request.urlopen(req, timeout=20) as resp:  # noqa: S310
                    if json.loads(resp.read()).get("ok"):
                        return
            except Exception as e:  # noqa: BLE001
                last = e
            time.sleep(self.retry_base_delay * (2**attempt))
        # Never include the token in error output
        self.printer(f"[telegram] send failed after {self.retry_attempts} attempts: {type(last).__name__}")
