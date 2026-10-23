---
name: ego-browser
description: "Drive the user's ego lite browser (Windows) from WSL. Trigger: open or operate websites, fill forms, click, take screenshots, extract page data, web app testing, QA, dogfooding, or visually validating a local dev server. Prefer it over headless browsers."
---

# ego-browser from WSL

ego lite is a Chromium browser on the Windows host built for agents. The
`ego-browser` command in WSL is a wrapper around the Windows `ego-browser.exe`.

## Bootstrap

Before any browser task, run:

```bash
ego-browser skill
```

and follow its output. It prints the usage guide for the installed version and
ends with a line starting `[ego-browser:skill] end of guide`. If that line is
missing, the output was truncated: save it with
`ego-browser skill > "$(mktemp)"` and read the file in parts.

Use the guide's **Bash, Zsh** section: heredoc works through the wrapper.

## WSL rules the guide does not cover

- **Scripts run in Windows Node, not in WSL.** Every path a script reads or
  writes must be a Windows path with forward slashes, for example
  `C:/Users/<windows-user>/ego/shot.png`. Read the result from WSL at
  `/mnt/c/Users/<windows-user>/ego/shot.png`. Convert with `wslpath -m <path>`
  and `wslpath -u <path>`. WSL paths such as `/home/...` or `/tmp/...` do not
  exist for the script.
- **Local dev servers are reachable as `http://localhost:<port>`.** WSL runs
  with mirrored networking, so a server started in WSL answers the Windows
  browser on the same port. Bind it to `127.0.0.1` or `0.0.0.0`.
- **Elevation is handled by the wrapper.** ego lite rejects elevated callers,
  and SSH sessions (herdr, Pi) inherit the elevated boot session. The wrapper
  switches to a non-elevated WSL interop session on its own. If it reports
  `every WSL interop session is elevated`, do not retry: ask the user to open a
  WSL tab from a Windows Terminal profile that is not run as administrator.
- **`Cannot capture a screenshot while the window is minimized`**: restore the
  window, then capture again:

  ```js
  const { windowId, bounds } = await page.cdp("Browser.getWindowForTarget", {});
  if (bounds.windowState === "minimized")
    await page.cdp("Browser.setWindowBounds", { windowId, bounds: { windowState: "normal" } });
  ```

- **Close a finished task space with `await task.finish({ keep: [] })`.**
  `keep` is required; `[]` closes every agent Page.
- **`this machine is not WSL with interop enabled`** means ego lite cannot run
  here (for example a Linux VM). Tell the user and stop; do not install another
  browser unasked.
- **`ego-browser: ego-browser.exe not found`** means ego lite is not installed
  on Windows. Ask the user to install it from https://lite.ego.app/.

## Vendor references

The full vendor skill ships with ego lite under
`/mnt/c/Program Files/Citro Labs/ego lite/Application/<version>/ego-skills/ego-browser/`.
Read `references/clearing-state.md` there before clearing any cookie, cache, or
storage.
