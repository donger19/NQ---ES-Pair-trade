"""
tvfeed.py - TradingView websocket data feed for the NQ-ES pair trading model.

Built around the TViewAPI class pattern (sync websocket, qs_/cs_ sessions).
Private, local, educational use only.

Public module-level API (designed to be called from MATLAB via the py. bridge,
all data crosses the boundary as JSON strings):

    fetch_history_json(symbols_csv, resolution, n_bars, token) -> str
    start(symbols_csv, resolution, n_bars, token)              -> None
    get_bars_json(symbol)                                      -> str
    status_json()                                              -> str
    stop()                                                     -> None

Bar format: [unix_time_sec, open, high, low, close, volume]
"""

import json
import random
import re
import string
import threading
import time
import urllib.request

from websocket import WebSocketTimeoutException, create_connection

WS_URL = "wss://prodata.tradingview.com/socket.io/websocket?from=chart"
DEFAULT_TOKEN = "unauthorized_user_token"

_token_cache = {}


def resolve_token(token):
    """
    Accepts either a ready auth token (JWT, contains dots) or a raw
    TradingView `sessionid` browser cookie. A sessionid is exchanged for
    the account's auth token by fetching the site with the cookie set.
    Falls back to the anonymous token if the exchange fails.
    """
    token = (token or "").strip()
    if token in ("", DEFAULT_TOKEN):
        return DEFAULT_TOKEN
    if "." in token:          # already a JWT auth token
        return token
    if token in _token_cache:
        return _token_cache[token]
    try:
        req = urllib.request.Request(
            "https://www.tradingview.com/",
            headers={
                "Cookie": f"sessionid={token}",
                "User-Agent": "Mozilla/5.0 (private educational use)",
            })
        with urllib.request.urlopen(req, timeout=15) as resp:
            html = resp.read().decode("utf-8", errors="ignore")
        m = re.search(r'"auth_token"\s*:\s*"([^"]+)"', html)
        if m and m.group(1) not in ("", DEFAULT_TOKEN):
            _token_cache[token] = m.group(1)
            return m.group(1)
    except Exception:
        pass
    return DEFAULT_TOKEN


class TViewAPI():
    """
    Description:
        Session constants
    """
    WEBSOCKET = True
    CHART = False
    headers = json.dumps({
        "Origin": "https://data.tradingview.com",
        "user-agent": "<luukas21@icloud.com> private educational use"
        })
    skip_messages = ["series_loading", "series_completed",
                     "quote_completed", "du"]

    def __init__(self, token=DEFAULT_TOKEN):
        self.request_version = 1
        self.token = resolve_token(token)
        self.websocket_session = self.generate_sesssion(self.WEBSOCKET)
        self.chart_session = self.generate_sesssion(self.CHART)
        self.ws = None
        # series id -> tradingview symbol string
        self.series_symbols = {}
        # series id -> chart session that owns it (needed by request_more_data)
        self.series_sessions = {}

    def generate_sesssion(self, session: bool) -> str:
        """
        Description:
            Get {session prefix}_{random string}
        params:
            session (bool)
                True: for websocket
                False: for chart
        returns:
            (str) web socket session
        """
        string_length = 12
        letters = string.ascii_lowercase
        random_string = "".join(
            random.choice(letters) for i in range(string_length)
        )
        prefix = "qs" if session else "cs"
        return f"{prefix}_{random_string}"

    # ------------------------------------------------------------------
    # Protocol framing: every payload is wrapped as ~m~<len>~m~<json>
    # ------------------------------------------------------------------
    @staticmethod
    def prepend_header(message: str) -> str:
        return f"~m~{len(message)}~m~{message}"

    @staticmethod
    def construct_message(func: str, params: list) -> str:
        return json.dumps({"m": func, "p": params}, separators=(",", ":"))

    def send_message(self, func: str, params: list):
        self.ws.send(self.prepend_header(self.construct_message(func, params)))

    @staticmethod
    def split_frames(raw: str) -> list:
        """Split a raw websocket frame into individual payload strings."""
        return [p for p in re.split(r"~m~\d+~m~", raw) if p]

    # ------------------------------------------------------------------
    # Connection / subscription
    # ------------------------------------------------------------------
    def connect(self, symbols: list, resolution: str, n_bars: int):
        self.ws = create_connection(WS_URL, headers=json.loads(self.headers),
                                    timeout=15)
        self.send_message("set_auth_token", [self.token])
        self.series_symbols = {}
        self.series_sessions = {}
        # one chart session per symbol: unauthorized sessions are limited
        # to a single series each
        for i, symbol in enumerate(symbols, start=1):
            chart_session = self.generate_sesssion(self.CHART)
            symbol_id = f"symbol_{i}"
            series_id = f"sds_{i}"
            self.series_symbols[series_id] = symbol
            self.series_sessions[series_id] = chart_session
            self.send_message("chart_create_session", [chart_session, ""])
            self.send_message("resolve_symbol", [
                chart_session, symbol_id,
                '={"symbol":"' + symbol +
                '","adjustment":"splits","session":"regular"}'
            ])
            self.send_message("create_series", [
                chart_session, series_id, f"s{i}", symbol_id,
                str(resolution), int(n_bars)
            ])

    def request_more(self, series_id: str, n_bars: int):
        """
        Ask the server to extend `series_id` further back in time. Triggers
        another round of timescale_update messages followed by a fresh
        series_completed for that series.
        """
        self.send_message("request_more_data", [
            self.series_sessions[series_id], series_id, int(n_bars)
        ])

    def close(self):
        try:
            if self.ws is not None:
                self.ws.close()
        except Exception:
            pass
        self.ws = None

    # ------------------------------------------------------------------
    # Message parsing
    # ------------------------------------------------------------------
    def parse_payload(self, payload: str):
        """
        Parse one payload. Returns:
          ("heartbeat", token)               keep-alive that must be echoed
          ("bars", {symbol: {ts: bar}})      history or live bar updates
          ("series_completed", series_id)    a history page finished loading
                                             (series_id may be None if the
                                             server omits it)
          ("error", reason) / (None, None)   everything else
        """
        if payload.startswith("~h~"):
            return "heartbeat", payload
        try:
            msg = json.loads(payload)
        except (ValueError, TypeError):
            return None, None
        func = msg.get("m")
        if func == "series_completed":
            params = msg.get("p", [])
            series_id = params[1] if len(params) > 1 else None
            if not isinstance(series_id, str):
                series_id = None
            return "series_completed", series_id
        if func in ("critical_error", "protocol_error"):
            return "error", json.dumps(msg.get("p", []))
        if func not in ("timescale_update", "du"):
            return None, None
        out = {}
        params = msg.get("p", [])
        if len(params) < 2 or not isinstance(params[1], dict):
            return None, None
        for series_id, symbol in self.series_symbols.items():
            node = params[1].get(series_id)
            if not isinstance(node, dict):
                continue
            bars = {}
            for item in node.get("s", []):
                v = item.get("v", [])
                if len(v) >= 5:
                    ts = int(v[0])
                    vol = float(v[5]) if len(v) > 5 else 0.0
                    bars[ts] = [ts, float(v[1]), float(v[2]),
                                float(v[3]), float(v[4]), vol]
            if bars:
                out[symbol] = bars
        return ("bars", out) if out else (None, None)


# ----------------------------------------------------------------------
# One-shot history fetch (connect -> read until series completed -> close)
# ----------------------------------------------------------------------
def fetch_history(symbols, resolution="3", n_bars=5000, token=DEFAULT_TOKEN,
                  timeout_s=180, start_ts=None, max_pages=40, verbose=False):
    """
    Fetch historical bars, optionally paging backwards past the single
    create_series depth limit.

    A create_series request returns at most one server-side page of history
    (a few thousand bars). When `start_ts` (unix seconds) is given, each
    series is extended with request_more_data until its oldest bar reaches
    `start_ts`, the server stops receding, or `max_pages` is hit -- whichever
    comes first. With `start_ts=None` the behaviour is the original
    single-page fetch.

    Anonymous sessions are depth-capped by TradingView, so reaching
    `start_ts` is best-effort: always check the span of what comes back.
    """
    api = TViewAPI(token)
    api.connect(symbols, resolution, n_bars)
    collected = {s: {} for s in symbols}
    series_ids = list(api.series_symbols)
    done = set()
    pages = {sid: 0 for sid in series_ids}
    oldest_seen = {sid: None for sid in series_ids}
    # fallback when the server omits the series id on series_completed
    anon_completions = 0
    deadline = time.time() + timeout_s
    try:
        while len(done) < len(series_ids) and time.time() < deadline:
            try:
                raw = api.ws.recv()
            except WebSocketTimeoutException:
                break
            for payload in api.split_frames(raw):
                kind, data = api.parse_payload(payload)
                if kind == "heartbeat":
                    api.ws.send(api.prepend_header(data))
                elif kind == "bars":
                    for sym, bars in data.items():
                        collected[sym].update(bars)
                elif kind == "error":
                    raise RuntimeError(f"TradingView error: {data}")
                elif kind == "series_completed":
                    sid = data
                    if sid not in api.series_symbols:
                        # Unattributable completion: fall back to counting.
                        anon_completions += 1
                        if anon_completions >= len(series_ids):
                            done.update(series_ids)
                        continue
                    if sid in done:
                        continue
                    sym = api.series_symbols[sid]
                    bars = collected[sym]
                    oldest = min(bars) if bars else None
                    prev = oldest_seen[sid]
                    oldest_seen[sid] = oldest
                    receding = (prev is None or
                                (oldest is not None and oldest < prev))
                    want_more = (start_ts is not None and
                                 oldest is not None and
                                 oldest > start_ts and
                                 pages[sid] < max_pages and
                                 receding)
                    if want_more:
                        pages[sid] += 1
                        api.request_more(sid, n_bars)
                        # progress was made: allow another full window
                        deadline = time.time() + timeout_s
                        if verbose:
                            print(f"{sym}: page {pages[sid]}, "
                                  f"{len(bars)} bars, oldest {oldest}",
                                  flush=True)
                    else:
                        done.add(sid)
                        if verbose:
                            print(f"{sym}: done, {len(bars)} bars, "
                                  f"oldest {oldest}, pages {pages[sid]}",
                                  flush=True)
    finally:
        api.close()
    return {s: [collected[s][t] for t in sorted(collected[s])]
            for s in symbols}


def fetch_history_json(symbols_csv, resolution="3", n_bars=5000,
                       token=DEFAULT_TOKEN, start_ts=0, max_pages=40):
    symbols = [s.strip() for s in str(symbols_csv).split(",") if s.strip()]
    start = int(start_ts) if start_ts else None
    data = fetch_history(symbols, str(resolution), int(n_bars), str(token),
                         start_ts=start, max_pages=int(max_pages))
    return json.dumps(data)


# ----------------------------------------------------------------------
# Live feed: background thread keeps the socket open, buffers bar updates
# ----------------------------------------------------------------------
class LiveFeed:
    def __init__(self, symbols, resolution, n_bars, token):
        self.symbols = symbols
        self.resolution = str(resolution)
        self.n_bars = int(n_bars)
        self.token = resolve_token(token)
        self.lock = threading.Lock()
        # bars updated since the last get_bars() call, per symbol: {ts: bar}
        self.dirty = {s: {} for s in symbols}
        self.connected = False
        self.last_msg_time = 0.0
        self.last_error = ""
        self.stop_flag = threading.Event()
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        backoff = 1
        while not self.stop_flag.is_set():
            api = TViewAPI(self.token)
            try:
                api.connect(self.symbols, self.resolution, self.n_bars)
                with self.lock:
                    self.connected = True
                    self.last_error = ""
                backoff = 1
                api.ws.settimeout(90)
                while not self.stop_flag.is_set():
                    raw = api.ws.recv()
                    with self.lock:
                        self.last_msg_time = time.time()
                    for payload in api.split_frames(raw):
                        kind, data = api.parse_payload(payload)
                        if kind == "heartbeat":
                            api.ws.send(api.prepend_header(data))
                        elif kind == "bars":
                            with self.lock:
                                for sym, bars in data.items():
                                    self.dirty[sym].update(bars)
                        elif kind == "error":
                            raise RuntimeError(data)
            except Exception as exc:  # noqa: BLE001 - reconnect on anything
                with self.lock:
                    self.connected = False
                    self.last_error = str(exc)
            finally:
                api.close()
            if not self.stop_flag.is_set():
                # after reconnect create_series re-sends recent history,
                # so any gap is refilled automatically
                self.stop_flag.wait(backoff)
                backoff = min(backoff * 2, 60)

    def get_bars(self, symbol):
        with self.lock:
            bars = self.dirty.get(symbol, {})
            self.dirty[symbol] = {}
        return [bars[t] for t in sorted(bars)]

    def status(self):
        with self.lock:
            age = (time.time() - self.last_msg_time
                   if self.last_msg_time else -1)
            return {
                "connected": self.connected,
                "last_msg_age_s": round(age, 1),
                "last_error": self.last_error,
                "symbols": self.symbols,
                "authorized": self.token != DEFAULT_TOKEN,
            }

    def stop(self):
        self.stop_flag.set()


_live = None


def start(symbols_csv, resolution="3", n_bars=500, token=DEFAULT_TOKEN):
    """Start (or restart) the singleton live feed."""
    global _live
    stop()
    symbols = [s.strip() for s in str(symbols_csv).split(",") if s.strip()]
    _live = LiveFeed(symbols, str(resolution), int(n_bars), str(token))


def get_bars_json(symbol):
    if _live is None:
        return "[]"
    return json.dumps(_live.get_bars(str(symbol)))


def status_json():
    if _live is None:
        return json.dumps({"connected": False, "last_msg_age_s": -1,
                           "last_error": "not started", "symbols": [],
                           "authorized": False})
    return json.dumps(_live.status())


def stop():
    global _live
    if _live is not None:
        _live.stop()
        _live = None


def login(username, password):
    """Sign in with TradingView credentials and return the auth token."""
    import urllib.parse
    data = urllib.parse.urlencode({
        "username": username,
        "password": password,
        "remember": "on",
    }).encode()
    req = urllib.request.Request(
        "https://www.tradingview.com/accounts/signin/",
        data=data,
        headers={
            "Origin": "https://www.tradingview.com",
            "Referer": "https://www.tradingview.com/",
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                          "(private educational use)",
        })
    with urllib.request.urlopen(req, timeout=20) as resp:
        body = json.loads(resp.read().decode("utf-8", errors="ignore"))
    user = body.get("user") or {}
    token = user.get("auth_token")
    if not token:
        err = body.get("error") or body.get("code") or str(body)[:200]
        raise RuntimeError(f"TradingView signin failed: {err}")
    return token


def _login_cli():
    import getpass
    import os
    print("TradingView sign-in (credentials are sent only to tradingview.com)")
    username = input("Username or email: ").strip()
    password = getpass.getpass("Password: ")
    token = login(username, password)
    cfg_path = os.path.join(os.path.dirname(os.path.dirname(
        os.path.abspath(__file__))), "config.json")
    with open(cfg_path, "r", encoding="utf-8") as fh:
        cfg = json.load(fh)
    cfg["tradingviewToken"] = token
    with open(cfg_path, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
    print(f"Auth token saved to {cfg_path}")
    print("Restart the dashboard to use it.")


if __name__ == "__main__":
    import sys
    if "--login" in sys.argv:
        _login_cli()
    else:
        # Quick standalone smoke test
        hist = fetch_history(["CME_MINI:NQ1!", "CME_MINI:ES1!"],
                             resolution="3", n_bars=100)
        for sym, bars in hist.items():
            print(sym, len(bars), "bars, last:", bars[-1] if bars else None)
