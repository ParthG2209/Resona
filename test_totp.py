#!/usr/bin/env python3
"""
Quick diagnostic to test sp_dc cookie + TOTP auth against Spotify.
Usage: python3 test_totp.py <your_sp_dc_cookie>
"""
import sys, json, hashlib, hmac, struct, time, urllib.request

SECRETS_URL = "https://raw.githubusercontent.com/xyloflake/spot-secrets-go/refs/heads/main/secrets/secretDict.json"
TOKEN_URL   = "https://open.spotify.com/api/token"
STIME_URL   = "https://open.spotify.com/api/server-time"
UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36"

def fetch_json(url, cookie=None):
    req = urllib.request.Request(url, headers={"User-Agent": UA})
    if cookie:
        req.add_header("Cookie", f"sp_dc={cookie}")
        req.add_header("Origin", "https://open.spotify.com")
        req.add_header("Referer", "https://open.spotify.com/")
    with urllib.request.urlopen(req, timeout=10) as resp:
        return json.loads(resp.read())

def create_totp_secret(data):
    """Matches JS: value ^ ((index % 33) + 9), join as strings, UTF-8 bytes"""
    mapped = [v ^ ((i % 33) + 9) for i, v in enumerate(data)]
    joined = "".join(str(x) for x in mapped)
    return joined.encode("utf-8")

def generate_totp(secret_bytes, timestamp_ms):
    """RFC 6238 TOTP: HMAC-SHA1, 6 digits, 30s period"""
    counter = int(timestamp_ms) // 1000 // 30
    counter_bytes = struct.pack(">Q", counter)
    h = hmac.new(secret_bytes, counter_bytes, hashlib.sha1).digest()
    offset = h[19] & 0x0F
    code = ((h[offset] & 0x7F) << 24 |
            (h[offset+1] & 0xFF) << 16 |
            (h[offset+2] & 0xFF) << 8  |
            (h[offset+3] & 0xFF))
    return f"{code % 1_000_000:06d}"

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 test_totp.py <sp_dc_cookie>")
        sys.exit(1)
    
    sp_dc = sys.argv[1]
    print(f"[1/5] sp_dc = {sp_dc[:10]}...{sp_dc[-10:]}")

    # Fetch secrets
    print("[2/5] Fetching TOTP secrets...")
    secrets = fetch_json(SECRETS_URL)
    versions = sorted([int(k) for k in secrets.keys()])
    ver = str(versions[-1])
    print(f"  → Latest version: {ver}, array length: {len(secrets[ver])}")

    secret_bytes = create_totp_secret(secrets[ver])
    print(f"  → Secret bytes length: {len(secret_bytes)}")
    print(f"  → Secret hex (first 40): {secret_bytes.hex()[:40]}...")

    # Fetch server time
    print("[3/5] Fetching server time...")
    try:
        st_data = fetch_json(STIME_URL, cookie=sp_dc)
        server_time_s = float(st_data["serverTime"])
        server_time_ms = int(server_time_s * 1000)
        print(f"  → Server time: {server_time_s}s ({server_time_ms}ms)")
    except Exception as e:
        print(f"  → Server time failed ({e}), using local time")
        server_time_ms = int(time.time() * 1000)

    # Generate TOTPs
    local_ms = int(time.time() * 1000)
    print(f"\n[4/5] Generating TOTPs...")
    print(f"  Local time ms: {local_ms}")
    print(f"  Server time ms: {server_time_ms}")
    print(f"  Server/30: {server_time_ms // 30}")

    local_totp = generate_totp(secret_bytes, local_ms)
    server_totp = generate_totp(secret_bytes, server_time_ms // 30)
    print(f"  → totp (local):  {local_totp}")
    print(f"  → totp (server): {server_totp}")
    print(f"  → totpVer:       {ver}")

    # Token request
    print(f"\n[5/5] Requesting token...")
    params = f"reason=init&productType=web_player&totp={local_totp}&totpVer={ver}&totpServer={server_totp}"
    full_url = f"{TOKEN_URL}?{params}"
    print(f"  URL: {TOKEN_URL}?reason=init&productType=web_player&totp={local_totp}&totpVer={ver}&totpServer={server_totp}")

    try:
        data = fetch_json(full_url, cookie=sp_dc)
        if "accessToken" in data:
            is_anon = data.get("isAnonymous", True)
            print(f"\n✅ SUCCESS! Token obtained (anonymous={is_anon})")
            print(f"  Token: {data['accessToken'][:30]}...")
            if is_anon:
                print("  ⚠️  Token is anonymous - sp_dc cookie may be invalid/expired")
        else:
            print(f"\n❌ Unexpected response: {json.dumps(data)[:200]}")
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        print(f"\n❌ HTTP {e.code}: {body[:300]}")
    except Exception as e:
        print(f"\n❌ Error: {e}")

if __name__ == "__main__":
    main()
