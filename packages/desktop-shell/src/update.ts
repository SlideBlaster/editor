/**
 * Desktop self-update. Contract: see update.md.
 *
 * Checks our GitHub Releases `latest.json` on startup (endpoint + minisign pubkey are
 * configured in tauri.conf.json), and — only with the user's consent — downloads,
 * installs, and relaunches. This updates the APP BINARY; it is entirely separate from a
 * user's decks, which are local files/git repos not tied to GitHub. Failures are
 * swallowed so a broken or offline update channel never blocks the editor.
 *
 * VERIFICATION: requires a signed release + a running Tauri build; cannot be exercised
 * headlessly. Typechecked against the plugin APIs only.
 */
import { check } from '@tauri-apps/plugin-updater'
import { relaunch } from '@tauri-apps/plugin-process'
import { ask } from '@tauri-apps/plugin-dialog'

export async function checkForUpdatesOnStartup(): Promise<void> {
  try {
    const update = await check()
    if (!update) return

    const accepted = await ask(
      `SlideBlaster ${update.version} is available (you have ${update.currentVersion}).\n\n` +
        'Download and install it now? The app will restart.',
      { title: 'Update available', kind: 'info' },
    )
    if (!accepted) return

    await update.downloadAndInstall()
    await relaunch()
  } catch (err) {
    // Offline, no release yet, or a signature mismatch: keep running the current version.
    console.error('update check failed; continuing on the current version', err)
  }
}
