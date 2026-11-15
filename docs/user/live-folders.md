# Live Folders

A Live Folder is a pinned folder that keeps itself filled from GitHub. It lists pull requests: yours, the ones waiting
for your review, or a repository's open ones. New pull requests come in at the top of the folder. Merged or closed ones
leave it.

## Making one

- **Space menu › New Live Folder…** (right after New Folder, as in Arc), the **+** menu, or type "live folder" in the
  Command Bar.
- Choose what it shows:
  - **Your Pull Requests**: the pull requests you opened and the ones waiting for your review ("Pull requests from you
    and your team will show up here automatically"). The folder is called **Pull Requests**, as Arc's is.
  - **Review Requests**: only the ones waiting for your review.
  - **A Repository**: a repository's open pull requests. Type `owner/name` or paste its GitHub address. Public
    repositories need no GitHub account.
- Filters: **Repository** (for your pull requests, only that repository's), **Author**, **Labels** (comma-separated; a
  pull request needs all of them) and **Include drafts**.

The folder goes at the top of the Space's pinned tabs. Its pull requests are ordinary pinned tabs: open them, move them
within the folder, rename them, open them in a split. Your own tabs can live in the same folder too. A refresh never
touches them.

## Staying up to date

- A Live Folder refreshes every three minutes. It also refreshes when you come back to Airc and its list is more than a
  minute old. Right-click it and choose **Refresh** to refresh it now.
- An unchanged list costs nothing: Airc asks GitHub only for what changed (ETags).
- A pull request that is **merged or closed leaves the folder**, as in Arc. If its page is on screen, it waits until you
  move on.
- **Keep in Folder** (right-click a pull request) makes it your own tab. It stays after the pull request ends.
- If you remove a pull request's tab, it doesn't come back while that pull request is open.
- A renamed pull request tab keeps your name. Otherwise a tab follows the pull request's title.

## The folder's menu

Right-click a Live Folder. Above the usual folder items (Rename, Copy All Links…), you'll find:

- The folder's state: "Updated 2 minutes ago", or what went wrong.
- **Refresh**.
- **Created by Me**, **Review Requests**, **Drafts**: Arc's filters. Each change lists the folder again.
- **Repositories ›**: narrow your pull requests to one repository. "This list is generated based on your currently
  active pull requests."
- **Edit Live Folder…**: the source, the filters and the GitHub account.
- **Stop Updating**: the folder becomes an ordinary folder. Its tabs stay, and nothing refreshes it again.

**Delete Folder** removes it like any folder, and ⌘Z brings it back as a Live Folder.

## When it can't update

The end of the folder's row says why. Hover over it for the details, or click it for the menu:

| Row | Meaning | What happens |
|---|---|---|
| **Sign In** | "Not signed in to GitHub": this folder needs an account, or GitHub no longer accepts its token (expired or revoked). | It waits for you to sign in (Edit Live Folder… or Sign In to GitHub… in its menu). |
| **Rate Limited** | "GitHub rate limit exceeded". Without an account, GitHub allows 60 requests an hour. | It waits for GitHub's reset time (shown in the tooltip). Refresh is off until then. |
| **Offline** | No connection. | It shows the last list it got and tries again a minute later, then less and less often (up to every 30 minutes). |
| **Not Found** | The repository doesn't exist, or it's private and you're not signed in. | Same as a failure. |
| **Failed** | "Failed to update", with GitHub's reason. | Same as offline. |

The folder's tabs stay as they are whenever it can't update.

## Your GitHub account

Each profile has its own GitHub account, as it has its own website logins. Sign in from the Live Folder sheet:

- **Sign In with GitHub…**: Airc shows a short code, copies it, and opens github.com/login/device. Enter the code there
  and approve. This appears only in builds that have Airc's GitHub app (see "For the maintainer").
- **Personal access token**: paste a token and choose **Use Token**. A fine-grained token with read-only access to
  **Pull requests** and **Metadata** is enough. A classic token needs `repo` for private repositories.

The token is kept in your macOS Keychain (item "Airc GitHub", one per profile). It isn't in Airc's files, backups or
sync. **Sign Out** in the sheet removes it. Airc talks to GitHub only for Live Folders, and only with that profile's
token.

## Sync and other Macs

A Live Folder's settings (its source, filters and state) stay on this Mac. The folder and its current tabs sync like
any folder. On your other Macs it's an ordinary folder that this Mac keeps current. To make it live there too, make a
Live Folder on that Mac.

A backup restores the folder and its tabs as an ordinary folder. A private window has no Live Folders. Arc's imported
Live Folders come over as ordinary folders.

## For the maintainer: GitHub sign-in

The device flow needs a GitHub OAuth App's client ID. The client ID isn't a secret; the app never uses a client secret.

1. On GitHub, go to **Settings › Developer settings › OAuth Apps › New OAuth App** (for an organization: the
   organization's **Settings › Developer settings › OAuth Apps**).
2. Fill it in:
   - **Application name**: Airc
   - **Homepage URL**: https://aircbrowser.com
   - **Authorization callback URL**: https://aircbrowser.com (the device flow doesn't use it, but GitHub requires one)
3. Choose **Register application**, then tick **Enable Device Flow** on the app's page and **Update application**.
4. Copy the **Client ID** (it starts with `Ov23` or `Iv1.`). Don't generate a client secret.
5. Put it in the app's Info.plist as `AircGitHubClientID` (a string). For a quick local test,
   `defaults write org.airc.Airc AircGitHubClientID <client id>` works too.

Airc asks for the `repo` and `read:org` scopes, so private repositories and team review requests show. GitHub's OAuth
Apps have no read-only scope for private repositories. A personal access token is the read-only alternative.
