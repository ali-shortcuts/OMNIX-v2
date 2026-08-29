# OMNIX — Install Guide (with troubleshooting)

## What you need

- Windows 10/11
- Microsoft Office (Click-to-Run or MSI, 2013 or newer, x86 or x64 — detected automatically)
- An API key for at least one cloud provider (e.g. Gemini — free daily tier), **or** a local AI server (Ollama / LM Studio)

## Install

1. Download `OMNIX-Setup-1.0.0.exe` — a single file.
2. Run it. If SmartScreen shows **"Windows protected your PC"**: click *More info* → *Run anyway* (see honesty note in README — the temporary self-signed certificate causes this; a real Authenticode certificate removes it).
3. Close Office if it is running, then finish the installer.
   - If the **VSTO Runtime** is missing, it is downloaded from Microsoft and installed — this is the only step that may show an Administrator prompt.
4. Open Excel (or Word / PowerPoint). You will find the **OMNIX** tab right after **Home**.
5. Click **Open Workspace** — the docked panel opens on the right side of your document.
6. Open **Settings** in the panel:
   - Choose a provider, paste your API key (stored DPAPI-encrypted), click **Test connection**.
   - Privacy Mode: `Local Only`, `Cloud Allowed`, or `Ask before sending` (default).
7. Chat! The bottom bar shows exactly what the AI currently "sees" of your document.

## Uninstall

Start Menu → OMNIX → Uninstall OMNIX. It removes the registry registrations, cleans Office's DisabledItems, untrusts the certificate, and (after your confirmation) deletes settings and history.

## Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| OMNIX tab does not appear | 1) Check `%LOCALAPPDATA%\OMNIX\logs\startup-debug.log` and `install-debug.log`. 2) Office may have silently disabled a previously broken add-in: File → Options → Add-ins → Manage: Disabled Items → enable OMNIX (the installer cleans this automatically for *its own* previous versions). 3) VSTO Runtime missing — rerun the installer. |
| "This mode only works with local AI" | Privacy Mode is *Local Only* but a cloud provider is selected. Switch to Ollama/LM Studio or change Privacy Mode. |
| "The provider rejected the API key" | AUTH_ERROR — re-enter the key in Settings and Test connection. |
| "Model is not available" | MODEL_ERROR — press *Load models* and pick a model the provider offers. |
| Request always times out | TIMEOUT — pick a faster model, or check local server ports (Ollama 11434 / LM Studio 1234). |
| "…does not support image analysis" | That provider/model cannot accept images. Use Gemini or a Vision-capable model for image questions. |
| Panel feels frozen during long answers | It should not — if a stream hangs, press **Stop** (a real HTTP cancellation). |
| Chat history missing after reopening a file | History is stored per document name; unnamed/new documents use a shared "unnamed" slot. |

## Data locations

| What | Where |
| --- | --- |
| Settings + encrypted keys | `%LOCALAPPDATA%\OMNIX\settings.dat` |
| Logs | `%LOCALAPPDATA%\OMNIX\logs\*.log` |
| Chat history | `%LOCALAPPDATA%\OMNIX\history\*.json` |
| Program files | `%LOCALAPPDATA%\Programs\OMNIX` |

## راهنمای سریع فارسی

۱. فایل `OMNIX-Setup-1.0.0.exe` را دانلود و اجرا کنید (فقط همین یک فایل).
۲. اگر ویندوز هشدار SmartScreen داد: More info → Run anyway.
۳. برنامه‌های Office را ببندید و نصب را تمام کنید. در صورت نبود VSTO Runtime، فقط همان مرحله ممکن است اجازهٔ Administrator بخواهد.
۴. Excel/Word/PowerPoint را باز کنید — تب **OMNIX** بعد از تب Home است.
۵. دکمهٔ **Open Workspace** را بزنید — پنل کنار سند باز می‌شود (نه تمام‌صفحه).
۶. در تب Settings پرووایدر و کلید API را وارد و تست کنید. حالت حریم خصوصی پیش‌فرض «Ask before sending» است.
۷. برای عیب‌یابی، لاگ‌ها در `%LOCALAPPDATA%\OMNIX\logs` هستند.

نکتهٔ صداقت: تا زمان امضای واقعی (Authenticode) هشدار SmartScreen ممکن است دیده شود و این در README صادقانه ذکر شده است.
