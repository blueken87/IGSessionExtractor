# IGSessionExtractor

Tweak cho Instagram iOS: xuất cookie/session của tài khoản đang đăng nhập ra file JSON đúng định dạng `instagrapi` (`set_settings`).

## Cách dùng

1. Cài tweak, mở Instagram và đăng nhập tài khoản cần lấy.
2. **Lắc máy** để xuất ngay, hoặc đưa Instagram xuống background (tweak tự xuất).
3. File nằm trong thư mục `IGSession` của app (thường là `.../Documents/IGSession/`), gồm:
   - `ig_<username>_<user_id>.json` — settings để import.
   - `ig_<username>_<user_id>.sessionid.txt` — chỉ riêng sessionid.
   - `latest.json`, `latest.sessionid.txt` — bản mới nhất.
4. Copy file `.json` sang máy tính rồi chạy:

```bash
pip install instagrapi
python tools/import_session.py ig_xxx_1234567890.json
```

Script sẽ `set_settings`, kiểm tra bằng `account_info()`, rồi lưu lại session đã chuẩn hoá.

Nếu không thấy file, mở Filza vào `Documents/IGSession/` của container Instagram và gửi log `IGSessionExtractor.log`.

Nếu `set_settings` lỗi, dùng sessionid:

```python
from instagrapi import Client
cl = Client()
cl.login_by_sessionid(open("ig_xxx.sessionid.txt").read().strip())
print(cl.account_info().username)
```

## Tweak lấy gì

- Cookie Instagram từ `NSHTTPCookieStorage` (gồm `sessionid`, `ds_user_id`, `csrftoken`, `mid`, `ig_did`, `datr`, `rur`...).
- Header thật của app: `Authorization: Bearer IGT:2:...`, `X-IG-WWW-Claim`, `IG-U-RUR`, `X-MID`, device id, locale, timezone...
- `authorization_data` được giải mã từ header `Authorization` để giữ nguyên ngữ cảnh phiên.

## Lưu ý

- Session = toàn quyền truy cập tài khoản. Không commit file JSON lên repo công khai.
- Chỉ xuất tài khoản **đang đăng nhập** tại thời điểm lắc/background.
- Cookie có thể hết hạn; nếu `account_info()` báo `login_required`, đăng nhập lại app rồi xuất lại.
- App dùng iOS user-agent; `instagrapi` mặc định mô phỏng Android. Tweak lưu user-agent thật để giữ phiên, nhưng một số endpoint có thể cần Android UA — có thể bỏ key `user_agent` trong JSON nếu gặp lỗi.
- Tweak chỉ chạy trong `com.burbn.instagram`, không ảnh hưởng app khác.

## Build

GitHub Actions build trên macOS runner. Bản `.deb` nằm ở artifact của workflow.
