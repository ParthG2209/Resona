#!/usr/bin/env python3
"""
Test which HTTP clients work for Spotify token exchange.
Compares: Python urllib vs curl subprocess.
Usage: python3 test_clients.py <sp_dc_cookie>
"""
import sys, json, hashlib, hmac, struct, time, urllib.request, subprocess

SECRETS_URL = "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json"
TOKEN_URL   = "https://open.spotify.com/api/token"
STIME_URL   = "https://open.spotify.com/api/server-time"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"

def fetch_json_py(url, cookie=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if cookie:
        req.add_header("Cookie", f"sp_dc={cookie}")
        req.add_header("Origin", "https://open.spotify.com")
        req.add_header("Referer", "https://open.spotify.com/")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())

def create_totp_secret(data):
    mapped = [v ^ ((i % 33) + 9) for i, v in enumerate(data)]
    return "".join(str(x) for x in mapped).encode("utf-8")

def generate_totp(secret_bytes, timestamp_ms):
    counter = int(timestamp_ms) // 1000 // 30
    counter_bytes = struct.pack(">Q", counter)
    h = hmac.new(secret_bytes, counter_bytes, hashlib.sha1).digest()
    offset = h[19] & 0x0F
    code = ((h[offset] & 0x7F) << 24 | (h[offset+1] & 0xFF) << 16 |
            (h[offset+2] & 0xFF) << 8  | (h[offset+3] & 0xFF))
    return f"{code % 1_000_000:06d}"

def main():
    sp_dc = sys.argv[1]
    
    # Setup TOTP
    secrets = fetch_json_py(SECRETS_URL)
    ver = str(max(int(k) for k in secrets.keys()))
    secret_bytes = create_totp_secret(secrets[ver])
    
    # Get server time
    try:
        st_data = fetch_json_py(STIME_URL, cookie=sp_dc)
        server_time_ms = int(float(st_data["serverTime"]) * 1000)
    except:
        server_time_ms = int(time.time() * 1000)

    local_ms = int(time.time() * 1000)
    local_totp = generate_totp(secret_bytes, local_ms)
    server_totp = generate_totp(secret_bytes, server_time_ms // 30)
    
    url = f"{TOKEN_URL}?reason=init&productType=web_player&totp={local_totp}&totpVer={ver}&totpServer={server_totp}"
    print(f"TOTP: local={local_totp}, server={server_totp}, ver={ver}")
    print(f"URL: {url}\n")

    # ── Test 1: Python urllib ──
    print("=== TEST 1: Python urllib ===")
    try:
        result = fetch_json_py(url, cookie=sp_dc)
        token = result.get("accessToken", "")
        print(f"✅ SUCCESS — token={token[:30]}...\n")
    except urllib.error.HTTPError as e:
        print(f"❌ HTTP {e.code}: {e.read().decode()[:200]}\n")
    except Exception as e:
        print(f"❌ Error: {e}\n")

    # Regenerate TOTP (may have crossed a 30s boundary)
    local_ms = int(time.time() * 1000)
    local_totp = generate_totp(secret_bytes, local_ms)
    server_totp = generate_totp(secret_bytes, server_time_ms // 30)
    url = f"{TOKEN_URL}?reason=init&productType=web_player&totp={local_totp}&totpVer={ver}&totpServer={server_totp}"

    # ── Test 2: curl ──
    print("=== TEST 2: curl ===")
    try:
        result = subprocess.run([
            "/usr/bin/curl", "-s",
            "-H", f"Cookie: sp_dc={sp_dc}",
            "-H", f"User-Agent: {UA}",
            "-H", "Origin: https://open.spotify.com",
            "-H", "Referer: https://open.spotify.com/",
            url
        ], capture_output=True, text=True, timeout=15)
        print(f"curl output: {result.stdout[:300]}")
        if "accessToken" in result.stdout:
            print("✅ curl WORKS\n")
        else:
            print("❌ curl FAILED\n")
    except Exception as e:
        print(f"❌ curl error: {e}\n")

    # ── Test 3: curl with --http1.1 ──
    local_ms = int(time.time() * 1000)
    local_totp = generate_totp(secret_bytes, local_ms)
    url = f"{TOKEN_URL}?reason=init&productType=web_player&totp={local_totp}&totpVer={ver}&totpServer={server_totp}"
    
    print("=== TEST 3: curl --http1.1 ===")
    try:
        result = subprocess.run([
            "/usr/bin/curl", "-s", "--http1.1",
            "-H", f"Cookie: sp_dc={sp_dc}",
            "-H", f"User-Agent: {UA}",
            "-H", "Origin: https://open.spotify.com",
            "-H", "Referer: https://open.spotify.com/",
            url
        ], capture_output=True, text=True, timeout=15)
        print(f"curl output: {result.stdout[:300]}")
        if "accessToken" in result.stdout:
            print("✅ curl --http1.1 WORKS\n")
        else:
            print("❌ curl --http1.1 FAILED\n")
    except Exception as e:
        print(f"❌ curl error: {e}\n")

if __name__ == "__main__":
    main()
