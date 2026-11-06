// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
//
// The Command Bar's built-in list of well-known sites (1763 of them), read by CommonSites.swift.
//
// Provenance: written by hand by the Airc authors in November 2026, from general knowledge of well-known sites: their
// names, their most useful entry pages and the short names people type for them. It is not copied or derived from any
// third-party ranking or popularity list (no Alexa, Tranco, Majestic, Cisco Umbrella, Cloudflare Radar or Chrome UX
// Report data). Tiers and regions are the authors' judgement. Licence: Apache-2.0, like the rest of Airc. Site names
// are their owners' trademarks, used only to name the sites.
//
// One site per line: tier|Name|entry URL without https://|aliases and other domains|regions
// - tier: 1 a household name, 2 well known, 3 known.
// - aliases: short or other names ("yt", "google mail") and other domains the site goes by ("gmail.com"), comma-separated.
//   The site's own domain is the entry URL's host or one of these.
// - regions: lowercase ISO codes the site is for ("uk" for Great Britain, "eu" for Europe-wide); empty for everywhere.
// Edit by hand; keep one entry URL per site (CommonSitesTests checks the format and duplicates).

enum CommonSitesData {
    static let list = #"""
# Search and portals
1|Google|www.google.com|goog
2|Google Images|images.google.com|gimages,google image search
2|Google News|news.google.com|gnews
1|Google Maps|www.google.com/maps|maps.google.com,gmaps,gmap
1|Google Translate|translate.google.com|gtranslate,translator
2|Google Flights|www.google.com/travel/flights|gflights
2|Google Scholar|scholar.google.com|gscholar
2|Google Earth|earth.google.com|gearth
1|Bing|www.bing.com
1|DuckDuckGo|duckduckgo.com|ddg
2|Ecosia|www.ecosia.org
2|Kagi|kagi.com
2|Startpage|www.startpage.com
2|Brave Search|search.brave.com
2|Qwant|www.qwant.com||fr,eu
1|Yahoo|www.yahoo.com
2|Yahoo Mail|mail.yahoo.com|ymail
1|Yandex|yandex.com|yandex.ru
1|Baidu|www.baidu.com
2|Naver|www.naver.com||kr
2|Ask|www.ask.com
2|AOL|www.aol.com
2|Perplexity|www.perplexity.ai|pplx
2|You.com|you.com
2|Wolfram Alpha|www.wolframalpha.com|wolfram
# Google apps
1|Gmail|mail.google.com|gmail.com,gm,google mail,googlemail.com
1|Google Calendar|calendar.google.com|gcal,gcalendar,cal
1|Google Drive|drive.google.com|gdrive
1|Google Docs|docs.google.com|gdocs
1|Google Sheets|docs.google.com/spreadsheets|sheets.google.com,gsheets,spreadsheets
1|Google Slides|docs.google.com/presentation|slides.google.com,gslides
2|Google Forms|docs.google.com/forms|forms.google.com,gforms
1|Google Meet|meet.google.com|gmeet
2|Google Chat|chat.google.com|gchat
2|Google Keep|keep.google.com|gkeep
1|Google Photos|photos.google.com|gphotos
2|Google Contacts|contacts.google.com|gcontacts
2|Google Account|myaccount.google.com|google account
2|Google One|one.google.com
1|Gemini|gemini.google.com|bard,google gemini,google ai
2|NotebookLM|notebooklm.google.com|notebook lm
2|Google AI Studio|aistudio.google.com|ai studio
2|Google Analytics|analytics.google.com|ga,ganalytics
2|Google Search Console|search.google.com/search-console|search console,gsc
2|Google Ads|ads.google.com|adwords
2|Google Cloud Console|console.cloud.google.com|gcp,google cloud,cloud.google.com
2|Firebase|console.firebase.google.com|firebase.google.com
2|Google Play|play.google.com|play store
2|Google Fonts|fonts.google.com|gfonts
2|Google Trends|trends.google.com|gtrends
2|Google Classroom|classroom.google.com
2|Google Sites|sites.google.com
2|Google Groups|groups.google.com
2|Google Admin|admin.google.com
2|Google Workspace|workspace.google.com|g suite
2|Google Books|books.google.com
2|Google Arts & Culture|artsandculture.google.com
2|Google Store|store.google.com
2|Google Finance|www.google.com/finance|gfinance
2|Google Colab|colab.research.google.com|colab,colaboratory
2|Google Passwords|passwords.google.com|google password manager
2|Google Voice|voice.google.com|gvoice
2|Google Tasks|tasks.google.com
2|Google Wallet|wallet.google.com|google pay,pay.google.com
2|Blogger|www.blogger.com|blogspot.com
1|YouTube|www.youtube.com|yt,youtu.be,m.youtube.com
1|YouTube Music|music.youtube.com|ytm,yt music
2|YouTube Studio|studio.youtube.com|yt studio
2|YouTube Kids|www.youtubekids.com
2|YouTube TV|tv.youtube.com|yttv
# Microsoft
1|Outlook|outlook.office.com|outlook.com,outlook.live.com,hotmail.com,hotmail,owa,ms mail
1|Microsoft 365|www.office.com|m365.cloud.microsoft,m365,office 365,o365,microsoft365.com,office
1|Microsoft Teams|teams.microsoft.com|teams,msteams,teams.live.com
1|OneDrive|onedrive.live.com|onedrive.com,one drive
2|Word|www.office.com/launch/word|ms word,microsoft word,word online
2|Excel|www.office.com/launch/excel|ms excel,microsoft excel,excel online
2|PowerPoint|www.office.com/launch/powerpoint|ppt,ms powerpoint,microsoft powerpoint
2|OneNote|www.onenote.com
2|SharePoint|www.office.com/launch/sharepoint|sharepoint.com
1|Microsoft|www.microsoft.com|ms
2|Microsoft Account|account.microsoft.com|ms account
2|Microsoft Learn|learn.microsoft.com|msdn,docs.microsoft.com
2|Microsoft Azure|portal.azure.com|azure,azure.microsoft.com,azure portal
1|Microsoft Copilot|copilot.microsoft.com|copilot,bing chat
2|Microsoft To Do|to-do.office.com|todo,ms todo
2|Microsoft Store|apps.microsoft.com|ms store
2|Xbox|www.xbox.com
2|Microsoft Edge Add-ons|microsoftedge.microsoft.com/addons|edge addons
2|Microsoft Forms|forms.office.com|ms forms
2|Power BI|app.powerbi.com|powerbi,powerbi.com
2|Microsoft Planner|tasks.office.com|planner
2|Clipchamp|app.clipchamp.com|clipchamp.com
2|Bing Maps|www.bing.com/maps
2|MSN|www.msn.com
# Apple
1|Apple|www.apple.com
1|iCloud|www.icloud.com|icloud mail,find my
2|Apple Music|music.apple.com
2|Apple TV+|tv.apple.com|apple tv,appletv
2|Apple Support|support.apple.com
2|Apple Developer|developer.apple.com|apple dev,wwdc
2|App Store Connect|appstoreconnect.apple.com|asc,itunes connect
2|Apple Account|account.apple.com|apple id,appleid.apple.com
2|Apple Maps|maps.apple.com
2|Apple Podcasts|podcasts.apple.com
2|Apple Community|discussions.apple.com|apple discussions
2|TestFlight|testflight.apple.com
# Social
1|Facebook|www.facebook.com|fb,fb.com,m.facebook.com
1|Messenger|www.messenger.com|fb messenger
1|Instagram|www.instagram.com|ig,insta
1|X|x.com|twitter.com,twitter,tw,twttr
1|LinkedIn|www.linkedin.com|li,lnkd.in
1|Reddit|www.reddit.com|old.reddit.com
1|TikTok|www.tiktok.com|tt
1|Pinterest|www.pinterest.com|pin
1|Snapchat|web.snapchat.com|snapchat.com,snap
2|Threads|www.threads.com|threads.net
2|Bluesky|bsky.app|bluesky,bsky.social
2|Mastodon|mastodon.social|joinmastodon.org
2|Tumblr|www.tumblr.com
2|Quora|www.quora.com
2|VK|vk.com|vkontakte
2|Weibo|weibo.com
2|Xing|www.xing.com||de,at,ch
2|Nextdoor|nextdoor.com
2|Flickr|www.flickr.com
2|Behance|www.behance.net
2|Dribbble|dribbble.com|dribble
2|Goodreads|www.goodreads.com
2|Letterboxd|letterboxd.com
2|Strava|www.strava.com
2|Meetup|www.meetup.com
2|Product Hunt|www.producthunt.com|ph
2|Hacker News|news.ycombinator.com|hn,hackernews,ycombinator
2|Lobsters|lobste.rs|lobsters
2|Medium|medium.com
2|Substack|substack.com
2|Patreon|www.patreon.com
2|Ko-fi|ko-fi.com|kofi
2|Buy Me a Coffee|buymeacoffee.com|bmc
2|Linktree|linktr.ee|linktree
2|BeReal|bere.al|bereal
2|Imgur|imgur.com
2|9GAG|9gag.com
2|DeviantArt|www.deviantart.com
2|ArtStation|www.artstation.com
2|Untappd|untappd.com
2|Trustpilot|www.trustpilot.com
2|Glassdoor|www.glassdoor.com
2|Kununu|www.kununu.com||at,de,ch
# Messaging and calls
1|WhatsApp|web.whatsapp.com|whatsapp.com,wa,whatsapp web
1|Telegram|web.telegram.org|telegram.org,tg,telegram web
1|Discord|discord.com/app|discordapp.com,dc
1|Slack|app.slack.com|slack.com
1|Zoom|zoom.us|zoom.com
2|Signal|signal.org
2|Webex|www.webex.com|cisco webex
2|Whereby|whereby.com
2|Jitsi Meet|meet.jit.si|jitsi
2|Element|app.element.io|matrix,element.io
2|Viber|www.viber.com
2|WeChat|web.wechat.com|wechat.com,weixin
2|LINE|line.me
2|Loom|www.loom.com
2|Calendly|calendly.com
2|Cal.com|cal.com
2|Doodle|doodle.com
2|Proton Mail|mail.proton.me|protonmail,proton.me,protonmail.com
2|Proton Drive|drive.proton.me
2|Proton Calendar|calendar.proton.me
2|Proton Pass|pass.proton.me
2|Tuta|app.tuta.com|tutanota,tuta.com,tutanota.com
2|Fastmail|app.fastmail.com|fastmail.com
2|Zoho Mail|mail.zoho.com
2|Zoho|www.zoho.com
2|GMX|www.gmx.net|gmx.at,gmx.de,gmx.com|at,de,ch
2|Web.de|web.de|webde|de
2|Hey|app.hey.com|hey.com
2|Superhuman|mail.superhuman.com|superhuman.com
2|Mailchimp|mailchimp.com
# Video, streaming and TV
1|Netflix|www.netflix.com|nflx,nf
1|Prime Video|www.primevideo.com|amazon prime video,prime
1|Disney+|www.disneyplus.com|disney plus,disney
2|HBO Max|play.hbomax.com|hbomax.com,max.com,max,hbo,hbomax
2|Hulu|www.hulu.com
2|Paramount+|www.paramountplus.com|paramount plus,paramount
2|Peacock|www.peacocktv.com|peacock tv
1|Twitch|www.twitch.tv|ttv
2|Vimeo|vimeo.com
2|Dailymotion|www.dailymotion.com
2|Crunchyroll|www.crunchyroll.com|crunchy
2|Plex|app.plex.tv|plex.tv
2|Mubi|mubi.com
2|Rakuten TV|www.rakuten.tv
2|Pluto TV|pluto.tv|pluto
2|Tubi|tubitv.com|tubi
2|Kick|kick.com
2|Rumble|rumble.com
2|DAZN|www.dazn.com
2|Sky Go|www.sky.com/watch/sky-go|skygo
2|WOW|www.wowtv.de|wowtv,sky wow|de,at
2|Joyn|www.joyn.de|joyn.at|de,at
2|RTL+|plus.rtl.de|rtl plus,rtlplus|de,at
2|JustWatch|www.justwatch.com
2|IMDb|www.imdb.com
2|Rotten Tomatoes|www.rottentomatoes.com|rt
2|Trakt|trakt.tv
2|TV Time|www.tvtime.com|tvtime
2|Fandom|www.fandom.com|wikia
# Music and audio
1|Spotify|open.spotify.com|spotify.com,sp
2|SoundCloud|soundcloud.com
2|Bandcamp|bandcamp.com
2|Deezer|www.deezer.com
2|Tidal|listen.tidal.com|tidal.com
2|Amazon Music|music.amazon.com
2|Last.fm|www.last.fm|lastfm
2|Genius|genius.com|lyrics
2|Shazam|www.shazam.com
2|Pandora|www.pandora.com
2|iHeartRadio|www.iheart.com|iheartradio.com
2|TuneIn|tunein.com
2|Audible|www.audible.com|audible.de,audible.co.uk
2|Pocket Casts|play.pocketcasts.com|pocketcasts
2|Overcast|overcast.fm
2|Mixcloud|www.mixcloud.com
2|Discogs|www.discogs.com
2|Songkick|www.songkick.com
2|Radio.net|www.radio.net|radio.de,radio.at
2|Qobuz|play.qobuz.com|qobuz.com
2|Beatport|www.beatport.com
2|Musescore|musescore.com
2|Ultimate Guitar|www.ultimate-guitar.com|ug tabs
2|Splice|splice.com
2|Suno|suno.com
# AI tools
1|ChatGPT|chatgpt.com|chat.openai.com,gpt,openai chat,cgpt
1|Claude|claude.ai|anthropic claude
2|OpenAI|openai.com
2|OpenAI Platform|platform.openai.com|openai api,openai platform
2|Claude Console|console.anthropic.com|anthropic console,anthropic api,platform.claude.com
2|Anthropic|www.anthropic.com
2|Mistral Le Chat|chat.mistral.ai|le chat,mistral,mistral.ai|fr,eu
2|DeepSeek|chat.deepseek.com|deepseek.com
2|Grok|grok.com
2|Meta AI|www.meta.ai
2|Hugging Face|huggingface.co|hf,huggingface
2|Midjourney|www.midjourney.com|mj
2|Sora|sora.chatgpt.com|sora.com
2|Runway|app.runwayml.com|runwayml.com,runway ml
2|ElevenLabs|elevenlabs.io|eleven labs,11labs
2|Character.AI|character.ai|characterai,c.ai
2|Poe|poe.com
2|DeepL|www.deepl.com/translator|deepl translate|de,eu
2|Grammarly|app.grammarly.com|grammarly.com
2|QuillBot|quillbot.com
2|Leonardo AI|app.leonardo.ai|leonardo.ai
2|Ideogram|ideogram.ai
2|Krea|www.krea.ai
2|Replicate|replicate.com
2|Groq|console.groq.com|groq.com
2|OpenRouter|openrouter.ai
2|Cursor|cursor.com|cursor.sh
2|v0|v0.app|v0.dev
2|Lovable|lovable.dev
2|Bolt.new|bolt.new
2|Replit|replit.com
2|Windsurf|windsurf.com|codeium
2|GitHub Copilot|github.com/copilot|copilot chat
2|Phind|www.phind.com
2|Gamma|gamma.app
2|Otter|otter.ai
2|Fireflies|app.fireflies.ai|fireflies.ai
2|Jasper|www.jasper.ai
2|Copy.ai|www.copy.ai
2|Pi|pi.ai|inflection pi
2|Kimi|www.kimi.com|kimi.ai,moonshot
2|Qwen Chat|chat.qwen.ai|qwen
2|Descript|web.descript.com|descript.com
2|HeyGen|app.heygen.com|heygen.com
2|Synthesia|www.synthesia.io
2|Pika|pika.art
2|Luma AI|lumalabs.ai|luma dream machine
2|Udio|www.udio.com
2|Kaggle|www.kaggle.com
2|LMArena|lmarena.ai|chatbot arena,lmsys
2|Ollama|ollama.com
# Developer tools
1|GitHub|github.com|gh,git hub
2|GitHub Gist|gist.github.com|gist
2|GitHub Pull Requests|github.com/pulls|prs,pull requests
2|GitHub Notifications|github.com/notifications|gh notifications
2|GitHub Docs|docs.github.com
2|GitHub Status|www.githubstatus.com
1|GitLab|gitlab.com|gl
2|Bitbucket|bitbucket.org|bb
2|Stack Overflow|stackoverflow.com|so,stack overflow
2|Stack Exchange|stackexchange.com
2|Super User|superuser.com
2|Ask Ubuntu|askubuntu.com
2|Server Fault|serverfault.com
2|MDN Web Docs|developer.mozilla.org|mdn,mozilla docs
2|Can I use|caniuse.com|caniuse
2|npm|www.npmjs.com|npmjs
2|PyPI|pypi.org|pip
2|crates.io|crates.io|crates,cargo
2|Docs.rs|docs.rs
2|RubyGems|rubygems.org|gems
2|Packagist|packagist.org|composer
2|Maven Central|central.sonatype.com|maven
2|NuGet|www.nuget.org
2|pkg.go.dev|pkg.go.dev|go packages,godoc
2|Go|go.dev|golang,golang.org
2|Rust|www.rust-lang.org|rustlang
2|Python|www.python.org|python docs,docs.python.org
2|Node.js|nodejs.org|node
2|Deno|deno.com|deno.land
2|Bun|bun.sh|bun.com
2|TypeScript|www.typescriptlang.org|ts
2|React|react.dev|reactjs,reactjs.org
2|Next.js|nextjs.org|next
2|Vue.js|vuejs.org|vue
2|Svelte|svelte.dev|sveltekit
2|Angular|angular.dev|angular.io
2|Astro|astro.build
2|Tailwind CSS|tailwindcss.com|tailwind
2|Vite|vite.dev|vitejs.dev
2|Swift|www.swift.org
2|Kotlin|kotlinlang.org
2|Docker Hub|hub.docker.com|docker,docker.com
2|Kubernetes|kubernetes.io|k8s
2|Terraform Registry|registry.terraform.io|terraform,terraform.io
2|HashiCorp|www.hashicorp.com
2|regex101|regex101.com|regex
2|JSFiddle|jsfiddle.net
2|CodePen|codepen.io
2|CodeSandbox|codesandbox.io
2|StackBlitz|stackblitz.com
2|LeetCode|leetcode.com
2|HackerRank|www.hackerrank.com
2|Codewars|www.codewars.com
2|Advent of Code|adventofcode.com|aoc
2|DevDocs|devdocs.io
2|W3Schools|www.w3schools.com|w3
2|freeCodeCamp|www.freecodecamp.org|fcc
2|DEV Community|dev.to|devto
2|Hashnode|hashnode.com
2|Sourcegraph|sourcegraph.com
2|GitHub Codespaces|github.com/codespaces|codespaces
2|JetBrains|www.jetbrains.com
2|VS Code for the Web|vscode.dev|vscode,vs code
2|Visual Studio Code|code.visualstudio.com
2|Postman|web.postman.co|postman.com
2|Insomnia|insomnia.rest
2|Swagger Editor|editor.swagger.io|swagger
2|JWT.io|jwt.io|jwt
2|crontab.guru|crontab.guru|cron
2|Explain Shell|explainshell.com|explainshell
2|Shields.io|shields.io
2|SonarCloud|sonarcloud.io|sonar
2|Codecov|app.codecov.io|codecov.io
2|CircleCI|app.circleci.com|circleci.com
2|Travis CI|app.travis-ci.com|travis
2|Buildkite|buildkite.com
2|Sentry|sentry.io
2|Datadog|app.datadoghq.com|datadog,datadoghq.com
2|New Relic|one.newrelic.com|newrelic.com
2|Grafana|grafana.com
2|PagerDuty|app.pagerduty.com|pagerduty.com
2|Opsgenie|app.opsgenie.com|opsgenie.com
2|Honeycomb|ui.honeycomb.io|honeycomb.io
2|PostHog|app.posthog.com|posthog.com,eu.posthog.com
2|Mixpanel|mixpanel.com
2|Amplitude|app.amplitude.com|amplitude.com
2|Segment|app.segment.com|segment.com
2|LaunchDarkly|app.launchdarkly.com|launchdarkly.com
2|Plausible|plausible.io
2|Fathom|app.usefathom.com|usefathom.com
2|Hotjar|insights.hotjar.com|hotjar.com
# Cloud and hosting
1|AWS Console|console.aws.amazon.com|aws,amazon web services,aws.amazon.com
2|Vercel|vercel.com
2|Netlify|app.netlify.com|netlify.com
2|Cloudflare|dash.cloudflare.com|cloudflare.com,cf
2|Heroku|dashboard.heroku.com|heroku.com
2|Render|dashboard.render.com|render.com
2|Fly.io|fly.io|fly
2|Railway|railway.com|railway.app
2|DigitalOcean|cloud.digitalocean.com|digitalocean.com,do
2|Linode|cloud.linode.com|linode.com,akamai cloud
2|Hetzner|console.hetzner.cloud|hetzner.com,hetzner|de,eu
2|OVHcloud|www.ovhcloud.com|ovh,ovh.com|fr,eu
2|IONOS|www.ionos.com|ionos.de,ionos.at,1und1|de,at
2|Scaleway|console.scaleway.com|scaleway.com|fr,eu
2|Supabase|supabase.com/dashboard
2|Neon|console.neon.tech|neon.tech
2|PlanetScale|app.planetscale.com|planetscale.com
2|MongoDB Atlas|cloud.mongodb.com|mongodb,mongodb.com
2|Redis Cloud|app.redislabs.com|redis.io
2|Upstash|console.upstash.com|upstash.com
2|Convex|dashboard.convex.dev|convex.dev
2|Appwrite|cloud.appwrite.io|appwrite.io
2|Clerk|dashboard.clerk.com|clerk.com
2|Auth0|manage.auth0.com|auth0.com
2|Okta|www.okta.com
2|Stripe Dashboard|dashboard.stripe.com|stripe,stripe.com
2|Twilio|console.twilio.com|twilio.com
2|SendGrid|app.sendgrid.com|sendgrid.com
2|Resend|resend.com
2|Postmark|account.postmarkapp.com|postmarkapp.com
2|Mailgun|app.mailgun.com|mailgun.com
2|Algolia|dashboard.algolia.com|algolia.com
2|Namecheap|www.namecheap.com
2|GoDaddy|www.godaddy.com
2|Porkbun|porkbun.com
2|Squarespace Domains|domains.squarespace.com|google domains
2|Gandi|www.gandi.net
2|WordPress.com|wordpress.com|wp
2|WordPress.org|wordpress.org
2|Wix|www.wix.com
2|Squarespace|www.squarespace.com
2|Webflow|webflow.com
2|Framer|www.framer.com
2|Shopify Admin|admin.shopify.com|shopify,shopify.com
2|Ghost|ghost.org
2|Carrd|carrd.co
2|GitHub Pages|pages.github.com
2|Read the Docs|readthedocs.org|rtd
2|Uptime Robot|uptimerobot.com|uptimerobot
2|Speedtest|www.speedtest.net|ookla
2|Fast.com|fast.com
2|What Is My IP|whatismyipaddress.com|my ip,whatismyip
2|DownDetector|downdetector.com|downdetector
2|Is It Down|www.isitdownrightnow.com
2|Wayback Machine|web.archive.org|archive.org,internet archive
2|archive.today|archive.ph|archive.is
2|SSL Labs|www.ssllabs.com/ssltest|ssllabs
2|PageSpeed Insights|pagespeed.web.dev|pagespeed,lighthouse
2|GTmetrix|gtmetrix.com
2|DNS Checker|dnschecker.org
2|VirusTotal|www.virustotal.com
2|Have I Been Pwned|haveibeenpwned.com|hibp
2|1Password|my.1password.com|1password.com,1pw,1password.eu
2|Bitwarden|vault.bitwarden.com|bitwarden.com,bitwarden.eu
2|LastPass|lastpass.com
2|Dashlane|app.dashlane.com|dashlane.com
2|NordVPN|nordvpn.com
2|Proton VPN|protonvpn.com
2|Tailscale|login.tailscale.com|tailscale.com
2|Mullvad|mullvad.net
# Productivity and work
1|Notion|www.notion.so|notion.com
1|Trello|trello.com
1|Asana|app.asana.com|asana.com
1|Jira|www.atlassian.com/software/jira|atlassian.net,jira cloud
2|Confluence|www.atlassian.com/software/confluence
2|Atlassian|home.atlassian.com|atlassian.com
1|Linear|linear.app
2|Monday.com|monday.com|monday
2|ClickUp|app.clickup.com|clickup.com
2|Basecamp|launchpad.37signals.com|basecamp.com
2|Airtable|airtable.com
2|Coda|coda.io
2|Miro|miro.com
2|Mural|app.mural.co|mural.co
2|FigJam|www.figma.com/figjam|figjam
2|Whimsical|whimsical.com
2|Excalidraw|excalidraw.com
2|tldraw|www.tldraw.com
2|Lucidchart|lucid.app|lucidchart.com,lucid
2|draw.io|app.diagrams.net|diagrams.net,drawio
2|Obsidian|obsidian.md
2|Evernote|www.evernote.com
2|Todoist|app.todoist.com|todoist.com
2|TickTick|ticktick.com
2|Things|culturedcode.com/things
2|Any.do|www.any.do|anydo
2|Workflowy|workflowy.com
2|Roam Research|roamresearch.com|roam
2|Logseq|logseq.com
2|Craft|www.craft.do
2|Bear|bear.app
2|Dropbox|www.dropbox.com|db
2|Dropbox Paper|paper.dropbox.com
2|Box|app.box.com|box.com
2|WeTransfer|wetransfer.com|wt
2|Smash|fromsmash.com
2|pCloud|my.pcloud.com|pcloud.com
2|MEGA|mega.nz|mega.io
2|Sync.com|www.sync.com
2|Zapier|zapier.com
2|Make|www.make.com|integromat
2|n8n|n8n.io
2|IFTTT|ifttt.com
2|Typeform|admin.typeform.com|typeform.com
2|Tally|tally.so
2|Jotform|www.jotform.com
2|SurveyMonkey|www.surveymonkey.com
2|DocuSign|app.docusign.com|docusign.com
2|Dropbox Sign|app.hellosign.com|hellosign
2|Adobe Acrobat|acrobat.adobe.com|acrobat,adobe pdf
2|Smallpdf|smallpdf.com
2|iLovePDF|www.ilovepdf.com
2|PDF24|tools.pdf24.org|pdf24.org|de,at
2|Slite|slite.com
2|Front|app.frontapp.com|frontapp.com
2|Intercom|app.intercom.com|intercom.com
2|Zendesk|www.zendesk.com
2|Freshdesk|www.freshworks.com/freshdesk
2|HubSpot|app.hubspot.com|hubspot.com
2|Salesforce|login.salesforce.com|salesforce.com,sfdc
2|Pipedrive|app.pipedrive.com|pipedrive.com
2|Attio|app.attio.com|attio.com
2|Close|app.close.com|close.com
2|Apollo|app.apollo.io|apollo.io
2|Gong|app.gong.io|gong.io
2|Workday|www.workday.com
2|BambooHR|www.bamboohr.com
2|Personio|www.personio.com|personio.de,personio|de,at,eu
2|Gusto|app.gusto.com|gusto.com
2|Rippling|app.rippling.com|rippling.com
2|Deel|app.deel.com|deel.com
2|Remote|employ.remote.com|remote.com
2|Greenhouse|app.greenhouse.io|greenhouse.io
2|Lever|hire.lever.co|lever.co
2|Lattice|lattice.com
2|Culture Amp|www.cultureamp.com
2|Harvest|www.getharvest.com
2|Toggl Track|track.toggl.com|toggl,toggl.com
2|Clockify|app.clockify.me|clockify.me
2|QuickBooks|qbo.intuit.com|quickbooks.intuit.com,quickbooks
2|Xero|go.xero.com|xero.com
2|FreshBooks|my.freshbooks.com|freshbooks.com
2|Wave|my.waveapps.com|waveapps.com
2|sevDesk|my.sevdesk.de|sevdesk.de,sevdesk|de,at
2|Lexoffice|app.lexoffice.de|lexoffice.de,lexoffice|de
2|DATEV|www.datev.de||de
2|Odoo|www.odoo.com
2|SAP|www.sap.com
2|ServiceNow|www.servicenow.com
2|Expensify|www.expensify.com
2|Ramp|app.ramp.com|ramp.com
2|Brex|dashboard.brex.com|brex.com
2|Pleo|app.pleo.io|pleo.io|eu
2|Pitch|pitch.com
2|Prezi|prezi.com
2|Beautiful.ai|www.beautiful.ai
2|Grain|grain.com
2|Fathom Video|fathom.video
2|tl;dv|tldv.io|tldv
2|Krisp|krisp.ai
2|Reclaim|app.reclaim.ai|reclaim.ai
2|Motion|app.usemotion.com|usemotion.com
2|Notion Calendar|calendar.notion.so|notion calendar
2|Fantastical|fantastical.app
2|Sunsama|app.sunsama.com|sunsama.com
2|Shortcut|app.shortcut.com|shortcut.com,clubhouse
2|YouTrack|www.jetbrains.com/youtrack|youtrack
2|Wrike|www.wrike.com
2|Smartsheet|app.smartsheet.com|smartsheet.com
2|Teamwork|www.teamwork.com
2|Productboard|app.productboard.com|productboard.com
2|Canny|canny.io
2|Loomly|www.loomly.com
2|Buffer|publish.buffer.com|buffer.com
2|Hootsuite|hootsuite.com
2|Later|app.later.com|later.com
2|Sprout Social|app.sproutsocial.com|sproutsocial.com
2|Semrush|www.semrush.com
2|Ahrefs|app.ahrefs.com|ahrefs.com
2|Moz|moz.com
2|Similarweb|www.similarweb.com
2|Crunchbase|www.crunchbase.com
2|PitchBook|pitchbook.com
2|Dealroom|app.dealroom.co|dealroom.co|eu
2|AngelList|www.angellist.com|wellfound.com,wellfound
2|Carta|app.carta.com|carta.com
2|Y Combinator|www.ycombinator.com|yc
2|Indie Hackers|www.indiehackers.com
# Design
1|Figma|www.figma.com
2|Canva|www.canva.com
2|Adobe|www.adobe.com
2|Adobe Express|new.express.adobe.com|adobe express,express.adobe.com
2|Adobe Creative Cloud|creativecloud.adobe.com|creative cloud,adobe cc
2|Adobe Firefly|firefly.adobe.com|firefly
2|Adobe Stock|stock.adobe.com
2|Photopea|www.photopea.com
2|Sketch|www.sketch.com
2|Penpot|design.penpot.app|penpot.app
2|Spline|app.spline.design|spline.design
2|Rive|rive.app
2|Unsplash|unsplash.com
2|Pexels|www.pexels.com
2|Pixabay|pixabay.com
2|Shutterstock|www.shutterstock.com
2|Getty Images|www.gettyimages.com
2|Envato|elements.envato.com|envato.com
2|Freepik|www.freepik.com
2|Flaticon|www.flaticon.com
2|The Noun Project|thenounproject.com|noun project
2|Iconify|icon-sets.iconify.design|iconify
2|SF Symbols|developer.apple.com/sf-symbols
2|Lucide|lucide.dev
2|Font Awesome|fontawesome.com
2|Coolors|coolors.co
2|Adobe Color|color.adobe.com
2|Remove.bg|www.remove.bg
2|TinyPNG|tinypng.com
2|Squoosh|squoosh.app
2|Mobbin|mobbin.com
2|Awwwards|www.awwwards.com
2|Are.na|www.are.na|arena
2|Cosmos|www.cosmos.so
2|Savee|savee.it
2|Lottiefiles|lottiefiles.com|lottie
2|Blender|www.blender.org
2|Sketchfab|sketchfab.com
2|Kittl|www.kittl.com
2|VistaCreate|create.vista.com
# Shopping (global and US)
1|Amazon|www.amazon.com|amzn,amz
1|Amazon.de|www.amazon.de|amazon deutschland|de,at
2|Amazon.co.uk|www.amazon.co.uk|amazon uk|uk,ie
2|Amazon.fr|www.amazon.fr||fr,be
2|Amazon.it|www.amazon.it||it
2|Amazon.es|www.amazon.es||es
2|Amazon.nl|www.amazon.nl||nl,be
2|Amazon.ca|www.amazon.ca||ca
2|Amazon.co.jp|www.amazon.co.jp||jp
2|Amazon.in|www.amazon.in||in
2|Amazon.com.au|www.amazon.com.au||au
2|Amazon.se|www.amazon.se||se
2|Amazon.pl|www.amazon.pl||pl
2|Amazon Orders|www.amazon.com/gp/css/order-history|amazon orders,your orders
1|eBay|www.ebay.com
2|eBay.de|www.ebay.de||de,at
2|eBay.co.uk|www.ebay.co.uk||uk
2|Kleinanzeigen|www.kleinanzeigen.de|ebay kleinanzeigen,ebay-kleinanzeigen.de|de
1|AliExpress|www.aliexpress.com|ali
2|Alibaba|www.alibaba.com
2|Temu|www.temu.com
2|Shein|www.shein.com
2|Etsy|www.etsy.com
2|Walmart|www.walmart.com||us
2|Target|www.target.com||us
2|Best Buy|www.bestbuy.com||us,ca
2|Costco|www.costco.com||us,ca
2|Home Depot|www.homedepot.com||us
2|Lowe's|www.lowes.com||us
2|Kroger|www.kroger.com||us
2|Instacart|www.instacart.com||us,ca
2|Wayfair|www.wayfair.com
2|IKEA|www.ikea.com
2|Apple Store|www.apple.com/store|apple store
2|Newegg|www.newegg.com||us
2|B&H Photo|www.bhphotovideo.com|b&h|us
2|Macy's|www.macys.com||us
2|Nordstrom|www.nordstrom.com||us
2|Sephora|www.sephora.com
2|Ulta|www.ulta.com||us
2|Nike|www.nike.com
2|Adidas|www.adidas.com
2|Puma|eu.puma.com|puma.com
2|New Balance|www.newbalance.com
2|Patagonia|www.patagonia.com
2|The North Face|www.thenorthface.com|tnf
2|Uniqlo|www.uniqlo.com
2|H&M|www2.hm.com|hm.com,h&m,hm
2|Zara|www.zara.com
2|COS|www.cos.com
2|Mango|shop.mango.com|mango.com
2|ASOS|www.asos.com
2|Zalando|www.zalando.at|zalando.de,zalando.com,zalando.ch,zalando|at,de,ch,eu
2|About You|www.aboutyou.at|aboutyou.de,aboutyou|at,de
2|Vinted|www.vinted.at|vinted.de,vinted.com,vinted|at,de,fr,eu
2|Depop|www.depop.com
2|Poshmark|poshmark.com
2|StockX|stockx.com
2|GOAT|www.goat.com
2|Farfetch|www.farfetch.com
2|Mytheresa|www.mytheresa.com
2|SSENSE|www.ssense.com
2|Net-a-Porter|www.net-a-porter.com
2|End Clothing|www.endclothing.com
2|Arket|www.arket.com
2|Everlane|www.everlane.com
2|Lululemon|shop.lululemon.com|lululemon.com
2|Decathlon|www.decathlon.com|decathlon.at,decathlon.de,decathlon.fr,decathlon
2|REI|www.rei.com||us
2|Bergfreunde|www.bergfreunde.at|bergfreunde.de|at,de
2|Bergzeit|www.bergzeit.at|bergzeit.de|at,de
2|Backcountry|www.backcountry.com||us
2|Chewy|www.chewy.com||us
2|Zooplus|www.zooplus.at|zooplus.de,zooplus.com,zooplus|at,de,eu
2|Fressnapf|www.fressnapf.at|fressnapf.de|at,de
2|Back Market|www.backmarket.com|backmarket.at,backmarket.de
2|Refurbed|www.refurbed.at|refurbed.de,refurbed|at,de
2|Idealo|www.idealo.at|idealo.de,idealo|at,de
2|Geizhals|geizhals.at|geizhals.de,geizhals.eu,geizhals|at,de
2|Camelcamelcamel|camelcamelcamel.com|camel
2|Honey|www.joinhoney.com
2|Rakuten|www.rakuten.com
2|Groupon|www.groupon.com
2|Craigslist|www.craigslist.org|cl|us,ca
2|Facebook Marketplace|www.facebook.com/marketplace|marketplace,fb marketplace
2|Gumtree|www.gumtree.com||uk,au
2|Wish|www.wish.com
2|Banggood|www.banggood.com
2|Bol.com|www.bol.com|bol|nl,be
2|Coolblue|www.coolblue.nl|coolblue.be,coolblue.de,coolblue|nl,be,de
2|Allegro|allegro.pl|allegro|pl
2|Cdiscount|www.cdiscount.com||fr
2|Fnac|www.fnac.com|fnac|fr
2|Darty|www.darty.com||fr
2|MediaMarkt|www.mediamarkt.at|mediamarkt.de,mediamarkt.ch,media markt|at,de,ch
2|Saturn|www.saturn.de||de
2|Otto|www.otto.de||de
2|Lidl|www.lidl.at|lidl.de,lidl.com,lidl|at,de,eu
2|Aldi|www.aldi.com|aldi-sued.de,aldi-nord.de
2|Tchibo|www.tchibo.at|tchibo.de,tchibo|at,de
2|dm|www.dm.at|dm.de,dm drogerie|at,de
2|Rossmann|www.rossmann.de||de
2|Douglas|www.douglas.at|douglas.de|at,de
2|Notino|www.notino.at|notino.de,notino|at,de,cz,eu
2|Flaconi|www.flaconi.at|flaconi.de|at,de
2|Thomann|www.thomann.de|thomann|de,at,eu
2|Conrad|www.conrad.at|conrad.de|at,de
2|Alternate|www.alternate.at|alternate.de|at,de
2|Cyberport|www.cyberport.at|cyberport.de|at,de
2|Galaxus|www.galaxus.at|galaxus.ch,galaxus.de,galaxus|ch,at,de
2|Brack|www.brack.ch||ch
2|Argos|www.argos.co.uk||uk
2|Tesco|www.tesco.com||uk,ie
2|Sainsbury's|www.sainsburys.co.uk|sainsburys|uk
2|Asda|www.asda.com||uk
2|Ocado|www.ocado.com||uk
2|John Lewis|www.johnlewis.com||uk
2|Marks & Spencer|www.marksandspencer.com|m&s,marks and spencer|uk
2|Boots|www.boots.com||uk
2|Currys|www.currys.co.uk||uk
2|Very|www.very.co.uk||uk
2|Screwfix|www.screwfix.com||uk
2|B&Q|www.diy.com||uk
2|Mercado Libre|www.mercadolibre.com|mercado livre,mercadolivre.com.br|br,mx,ar
2|Flipkart|www.flipkart.com||in
2|Rakuten Ichiba|www.rakuten.co.jp||jp
2|Taobao|www.taobao.com||cn
2|JD.com|www.jd.com|jingdong|cn
2|Coupang|www.coupang.com||kr
# Travel and maps
1|Booking.com|www.booking.com|booking
1|Airbnb|www.airbnb.com|airbnb.at,airbnb.de,airbnb.co.uk
2|Expedia|www.expedia.com
2|Hotels.com|www.hotels.com
2|Tripadvisor|www.tripadvisor.com|tripadvisor.at,tripadvisor.de
2|Kayak|www.kayak.com|kayak.de
2|Skyscanner|www.skyscanner.net|skyscanner.at,skyscanner.de,skyscanner.com,skyscanner
2|Momondo|www.momondo.com|momondo.at,momondo.de
2|Google Hotels|www.google.com/travel/hotels
2|Trivago|www.trivago.com|trivago.at,trivago.de
2|Agoda|www.agoda.com
2|Hostelworld|www.hostelworld.com
2|Vrbo|www.vrbo.com
2|Check24|www.check24.de|check24.at,check24|de,at
2|Opodo|www.opodo.com|opodo.de,opodo.at
2|eDreams|www.edreams.com
2|Omio|www.omio.com|omio.at,omio.de,goeuro
2|Trainline|www.thetrainline.com|trainline
2|Rome2Rio|www.rome2rio.com
2|FlixBus|www.flixbus.com|flixbus.at,flixbus.de,flixtrain
2|BlaBlaCar|www.blablacar.com|blablacar.de,blablacar.fr
2|Uber|m.uber.com|uber.com
2|Lyft|www.lyft.com||us,ca
2|Bolt|bolt.eu|bolt ride
2|FREE NOW|www.free-now.com|freenow,mytaxi
2|Lime|www.li.me
2|Ryanair|www.ryanair.com
2|easyJet|www.easyjet.com
2|Wizz Air|wizzair.com|wizz,wizzair
2|Lufthansa|www.lufthansa.com|lh
2|Austrian Airlines|www.austrian.com|aua,austrian|at
2|Swiss|www.swiss.com|swiss air,swiss international|ch
2|Eurowings|www.eurowings.com||de,at
2|British Airways|www.britishairways.com|ba|uk
2|Air France|www.airfrance.com|airfrance.fr,air france|fr
2|KLM|www.klm.com|klm.nl|nl
2|Emirates|www.emirates.com
2|Qatar Airways|www.qatarairways.com|qatar
2|Turkish Airlines|www.turkishairlines.com|thy
2|Delta|www.delta.com|delta air lines|us
2|United Airlines|www.united.com|united|us
2|American Airlines|www.aa.com||us
2|Southwest|www.southwest.com||us
2|JetBlue|www.jetblue.com||us
2|Air Canada|www.aircanada.com||ca
2|Iberia|www.iberia.com||es
2|Vueling|www.vueling.com||es
2|TAP Air Portugal|www.flytap.com|tap|pt
2|SAS|www.flysas.com||se,no,dk
2|Finnair|www.finnair.com||fi
2|Norwegian|www.norwegian.com||no
2|ITA Airways|www.ita-airways.com|alitalia|it
2|Condor|www.condor.com||de
2|Flightradar24|www.flightradar24.com|fr24,flightradar
2|FlightAware|www.flightaware.com
2|SeatGuru|www.seatguru.com
2|TripIt|www.tripit.com
2|Marriott|www.marriott.com|bonvoy
2|Hilton|www.hilton.com
2|Hyatt|www.hyatt.com
2|IHG|www.ihg.com
2|Accor|all.accor.com|accor.com,accorhotels
2|Hertz|www.hertz.com
2|Sixt|www.sixt.com|sixt.at,sixt.de
2|Europcar|www.europcar.com
2|Enterprise|www.enterprise.com
2|Avis|www.avis.com
2|Rentalcars|www.rentalcars.com
2|GetYourGuide|www.getyourguide.com
2|Viator|www.viator.com
2|Lonely Planet|www.lonelyplanet.com
2|Komoot|www.komoot.com|komoot.de
2|AllTrails|www.alltrails.com
2|Bergfex|www.bergfex.at|bergfex.com,bergfex|at,de,ch
2|Outdooractive|www.outdooractive.com
2|OpenStreetMap|www.openstreetmap.org|osm
2|Waze|www.waze.com
2|Citymapper|citymapper.com
2|what3words|what3words.com|w3w
2|Wanderlog|wanderlog.com
2|Seat61|www.seat61.com|seat 61
2|Polarsteps|www.polarsteps.com
# Food and delivery
2|Uber Eats|www.ubereats.com
2|DoorDash|www.doordash.com||us,ca,au
2|Grubhub|www.grubhub.com||us
2|Deliveroo|deliveroo.co.uk|deliveroo.com,deliveroo.fr,deliveroo|uk,fr,it,be,ie
2|Just Eat|www.just-eat.co.uk|justeat|uk,ie
2|Lieferando|www.lieferando.at|lieferando.de,lieferando|at,de
2|Takeaway.com|www.takeaway.com|thuisbezorgd.nl,takeaway|nl,be
2|Foodora|www.foodora.at|foodora.se,foodora.no,foodora|at,se,no
2|Wolt|wolt.com|wolt.at,wolt.de|at,de,fi,eu
2|Glovo|glovoapp.com|glovo|es,it,pl,pt
2|Flink|www.goflink.com|flink|de,nl,at
2|HelloFresh|www.hellofresh.com|hellofresh.at,hellofresh.de
2|OpenTable|www.opentable.com
2|TheFork|www.thefork.com|lafourchette,thefork.at,thefork.de
2|Resy|resy.com
2|Yelp|www.yelp.com
2|Zomato|www.zomato.com||in
2|Swiggy|www.swiggy.com||in
2|Too Good To Go|www.toogoodtogo.com|tgtg
2|Allrecipes|www.allrecipes.com
2|BBC Good Food|www.bbcgoodfood.com
2|Serious Eats|www.seriouseats.com
2|NYT Cooking|cooking.nytimes.com|nyt cooking
2|Chefkoch|www.chefkoch.de|chefkoch|de,at
2|Ichkoche|www.ichkoche.at|ichkoche|at
2|Gutekueche|www.gutekueche.at|gute küche|at
2|Marmiton|www.marmiton.org||fr
2|GialloZafferano|www.giallozafferano.it||it
2|Bon Appétit|www.bonappetit.com
2|Epicurious|www.epicurious.com
2|Tasty|tasty.co
2|Food Network|www.foodnetwork.com
2|Starbucks|www.starbucks.com
2|McDonald's|www.mcdonalds.com
2|Domino's|www.dominos.com
# Payments, banks and money (global, US, UK)
1|PayPal|www.paypal.com|pp
2|Wise|wise.com|transferwise
2|Revolut|app.revolut.com|revolut.com
2|N26|app.n26.com|n26.com,n26|de,at,eu
2|Monzo|monzo.com||uk
2|Starling Bank|www.starlingbank.com|starling|uk
2|Klarna|www.klarna.com
2|Venmo|venmo.com||us
2|Cash App|cash.app|cashapp|us
2|Zelle|www.zellepay.com||us
2|Chase|www.chase.com|jpmorgan chase|us
2|Bank of America|www.bankofamerica.com|bofa,boa|us
2|Wells Fargo|www.wellsfargo.com||us
2|Citi|www.citi.com|citibank|us
2|Capital One|www.capitalone.com||us
2|American Express|www.americanexpress.com|amex
2|Discover|www.discover.com||us
2|US Bank|www.usbank.com||us
2|Ally|www.ally.com||us
2|Charles Schwab|www.schwab.com||us
2|Fidelity|www.fidelity.com||us
2|Vanguard|investor.vanguard.com|vanguard.com
2|Robinhood|robinhood.com||us
2|E*TRADE|us.etrade.com|etrade.com,etrade|us
2|Interactive Brokers|www.interactivebrokers.com|ibkr
2|Credit Karma|www.creditkarma.com||us
2|YNAB|app.ynab.com|ynab.com,you need a budget
2|Monarch Money|app.monarchmoney.com|monarchmoney.com,monarch
2|Copilot Money|copilot.money
2|Mercury|app.mercury.com|mercury.com
2|TurboTax|turbotax.intuit.com|turbotax
2|IRS|www.irs.gov||us
2|HSBC|www.hsbc.com|hsbc.co.uk|uk
2|Barclays|www.barclays.co.uk|barclays|uk
2|Lloyds Bank|www.lloydsbank.com|lloyds|uk
2|NatWest|www.natwest.com||uk
2|Santander|www.santander.com|santander.co.uk,santander.de
2|Nationwide|www.nationwide.co.uk||uk
2|HMRC|www.gov.uk/government/organisations/hm-revenue-customs|hmrc|uk
2|Trading 212|www.trading212.com|t212
2|eToro|www.etoro.com
2|Trade Republic|app.traderepublic.com|traderepublic.com,trade republic|de,at,eu
2|Scalable Capital|de.scalable.capital|scalable.capital,scalable|de,at
2|Bitpanda|web.bitpanda.com|bitpanda.com|at,de,eu
2|Flatex|www.flatex.at|flatex.de|at,de
2|Degiro|trader.degiro.nl|degiro.com,degiro|eu
2|Comdirect|www.comdirect.de||de
2|ING|www.ing.com|ing.de,ing.at,ing.nl,ing|de,at,nl,be
2|DKB|www.dkb.de||de
2|Deutsche Bank|www.deutsche-bank.de|db.com|de
2|Commerzbank|www.commerzbank.de||de
2|Sparkasse|www.sparkasse.de||de
2|Volksbank|www.vr.de|volksbank.de|de
2|Postbank|www.postbank.de||de
2|Consorsbank|www.consorsbank.de||de
2|UBS|www.ubs.com||ch
2|PostFinance|www.postfinance.ch||ch
2|Raiffeisen Schweiz|www.raiffeisen.ch||ch
2|TWINT|www.twint.ch||ch
2|BNP Paribas|mabanque.bnpparibas|bnpparibas.com,bnp|fr
2|Société Générale|particuliers.sg.fr|societegenerale.com,societe generale|fr
2|Crédit Agricole|www.credit-agricole.fr|credit agricole|fr
2|Boursorama|www.boursorama.com|boursobank|fr
2|Intesa Sanpaolo|www.intesasanpaolo.com|intesa|it
2|UniCredit|www.unicredit.it||it
2|BBVA|www.bbva.es|bbva.com|es
2|CaixaBank|www.caixabank.es|caixabank|es
2|Rabobank|www.rabobank.nl|rabobank|nl
2|ABN AMRO|www.abnamro.nl|abn|nl
2|Bunq|www.bunq.com||nl,eu
2|Nordea|www.nordea.com||se,fi,dk,no
2|Swedbank|www.swedbank.se||se
2|Danske Bank|danskebank.dk|danskebank.com,danske|dk
2|Coinbase|www.coinbase.com
2|Binance|www.binance.com
2|Kraken|www.kraken.com
2|Crypto.com|crypto.com
2|CoinMarketCap|coinmarketcap.com|cmc
2|CoinGecko|www.coingecko.com
2|Etherscan|etherscan.io
2|OpenSea|opensea.io
2|MetaMask|metamask.io
2|Ledger|www.ledger.com
2|TradingView|www.tradingview.com|tv chart
2|Yahoo Finance|finance.yahoo.com|yfinance
2|Morningstar|www.morningstar.com
2|Investing.com|www.investing.com
2|MarketWatch|www.marketwatch.com
2|Seeking Alpha|seekingalpha.com
2|justETF|www.justetf.com||de,at,eu
2|finanzen.net|www.finanzen.net|finanzen.at|de,at
2|onvista|www.onvista.de||de
2|XE|www.xe.com|currency converter
2|Splitwise|secure.splitwise.com|splitwise.com
2|Curve|www.curve.com
2|Vivid Money|vivid.money|vivid|de,at
# News and magazines (international and US)
1|BBC|www.bbc.com|bbc.co.uk
2|BBC News|www.bbc.co.uk/news|bbc news
2|BBC Sport|www.bbc.co.uk/sport|bbc sport
2|BBC iPlayer|www.bbc.co.uk/iplayer|iplayer|uk
2|BBC Sounds|www.bbc.co.uk/sounds||uk
1|CNN|edition.cnn.com|cnn.com
2|The New York Times|www.nytimes.com|nyt,ny times,new york times
2|The Washington Post|www.washingtonpost.com|wapo,washington post
2|The Wall Street Journal|www.wsj.com|wsj,wall street journal
2|The Guardian|www.theguardian.com|guardian
2|Reuters|www.reuters.com
2|Associated Press|apnews.com|ap news,ap
2|Bloomberg|www.bloomberg.com
2|Financial Times|www.ft.com|ft
2|The Economist|www.economist.com|economist
2|Al Jazeera|www.aljazeera.com
2|Politico|www.politico.com|politico.eu
2|Axios|www.axios.com
2|NPR|www.npr.org||us
2|Fox News|www.foxnews.com|fox|us
2|NBC News|www.nbcnews.com|nbc|us
2|CBS News|www.cbsnews.com||us
2|ABC News|abcnews.go.com|abc news|us
2|USA Today|www.usatoday.com||us
2|Los Angeles Times|www.latimes.com|la times|us
2|The Atlantic|www.theatlantic.com|atlantic
2|The New Yorker|www.newyorker.com|new yorker
2|Time|time.com|time magazine
2|Newsweek|www.newsweek.com
2|Vox|www.vox.com
2|Vice|www.vice.com
2|HuffPost|www.huffpost.com|huffington post
2|Business Insider|www.businessinsider.com|insider
2|Forbes|www.forbes.com
2|Fortune|fortune.com
2|CNBC|www.cnbc.com
2|The Information|www.theinformation.com
2|Semafor|www.semafor.com
2|Euronews|www.euronews.com
2|DW|www.dw.com|deutsche welle
2|France 24|www.france24.com
2|Le Monde|www.lemonde.fr||fr
2|Le Figaro|www.lefigaro.fr|figaro|fr
2|Libération|www.liberation.fr|liberation|fr
2|El País|elpais.com|el pais|es
2|El Mundo|www.elmundo.es||es
2|Corriere della Sera|www.corriere.it|corriere|it
2|la Repubblica|www.repubblica.it|repubblica|it
2|NOS|nos.nl|nos nieuws|nl
2|de Volkskrant|www.volkskrant.nl|volkskrant|nl
2|NRC|www.nrc.nl||nl
2|The Times|www.thetimes.com|thetimes.co.uk,times|uk
2|The Telegraph|www.telegraph.co.uk|telegraph|uk
2|The Independent|www.independent.co.uk|independent|uk
2|Daily Mail|www.dailymail.co.uk|mail online|uk
2|Sky News|news.sky.com|sky news|uk
2|The Irish Times|www.irishtimes.com||ie
2|RTÉ|www.rte.ie|rte|ie
2|ABC Australia|www.abc.net.au||au
2|Sydney Morning Herald|www.smh.com.au|smh|au
2|CBC|www.cbc.ca||ca
2|The Globe and Mail|www.theglobeandmail.com||ca
2|Times of India|timesofindia.indiatimes.com|times of india,toi|in
2|The Hindu|www.thehindu.com||in
2|NHK|www3.nhk.or.jp|nhk.or.jp,nhk|jp
2|South China Morning Post|www.scmp.com|scmp
2|Haaretz|www.haaretz.com
2|Kyiv Independent|kyivindependent.com
# Tech news
2|The Verge|www.theverge.com|verge
2|TechCrunch|techcrunch.com|tc
2|Ars Technica|arstechnica.com|ars
2|Wired|www.wired.com
2|Engadget|www.engadget.com
2|9to5Mac|9to5mac.com
2|MacRumors|www.macrumors.com
2|AppleInsider|appleinsider.com
2|Daring Fireball|daringfireball.net|df
2|The Next Web|thenextweb.com|tnw
2|Gizmodo|gizmodo.com
2|Mashable|mashable.com
2|CNET|www.cnet.com
2|ZDNet|www.zdnet.com
2|Tom's Hardware|www.tomshardware.com
2|Stratechery|stratechery.com
2|Platformer|www.platformer.news
2|404 Media|www.404media.co
2|Rest of World|restofworld.org
2|MIT Technology Review|www.technologyreview.com|mit tech review
2|IEEE Spectrum|spectrum.ieee.org
2|Heise|www.heise.de|heise online,c't|de,at,ch
2|Golem|www.golem.de||de,at
2|t3n|t3n.de||de,at
2|Netzpolitik|netzpolitik.org||de
2|ComputerBase|www.computerbase.de||de
2|Caschys Blog|stadt-bremerhaven.de|caschy|de
2|Futurezone|futurezone.at||at
2|Trending Topics|www.trendingtopics.eu|trendingtopics.at|at
2|Der Brutkasten|brutkasten.com|brutkasten|at
2|Sifted|sifted.eu||eu
2|Tech.eu|tech.eu||eu
# Sports
2|ESPN|www.espn.com
2|Sky Sports|www.skysports.com||uk
2|The Athletic|www.nytimes.com/athletic|theathletic.com,athletic
2|Bleacher Report|bleacherreport.com|br
2|FlashScore|www.flashscore.com|flashscore.at,flashscore.de
2|SofaScore|www.sofascore.com
2|Livescore|www.livescore.com
2|FotMob|www.fotmob.com
2|Transfermarkt|www.transfermarkt.com|transfermarkt.de,transfermarkt.at,transfermarkt
2|Kicker|www.kicker.de||de,at
2|Sport1|www.sport1.de||de
2|Laola1|www.laola1.at|laola|at
2|UEFA|www.uefa.com
2|FIFA|www.fifa.com
2|Premier League|www.premierleague.com|epl
2|Bundesliga|www.bundesliga.com|bundesliga.de|de
2|NBA|www.nba.com
2|NFL|www.nfl.com||us
2|MLB|www.mlb.com||us
2|NHL|www.nhl.com
2|Formula 1|www.formula1.com|f1
2|MotoGP|www.motogp.com
2|ATP Tour|www.atptour.com|atp
2|Wimbledon|www.wimbledon.com
2|Olympics|www.olympics.com
2|Cricinfo|www.espncricinfo.com|cricinfo
2|Chess.com|www.chess.com
2|Lichess|lichess.org
2|Eurosport|www.eurosport.com|eurosport.de
2|Ski Austria|www.oesv.at|ösv|at
2|FIS|www.fis-ski.com
# Weather
2|Weather.com|weather.com|the weather channel
2|AccuWeather|www.accuweather.com
2|Windy|www.windy.com
2|Weather Underground|www.wunderground.com|wunderground
2|Yr|www.yr.no||no,eu
2|Meteoblue|www.meteoblue.com
2|wetter.com|www.wetter.com||de,at
2|wetter.at|www.wetter.at||at
2|GeoSphere Austria|www.geosphere.at|zamg,zamg.ac.at|at
2|Wetteronline|www.wetteronline.de|wetteronline.at|de,at
2|Kachelmannwetter|kachelmannwetter.com|kachelmann|de,at,ch
2|Met Office|www.metoffice.gov.uk|met office|uk
2|MeteoSwiss|www.meteoswiss.admin.ch|meteoschweiz|ch
2|Rain Viewer|www.rainviewer.com
2|Ventusky|www.ventusky.com
2|Zoom Earth|zoom.earth
2|Lawinenwarndienst|lawinen.report|avalanche report,lawinen|at
# Reference and learning
1|Wikipedia|www.wikipedia.org|wiki,wp,en.wikipedia.org
2|Wikipedia (Deutsch)|de.wikipedia.org|dewiki|de,at,ch
2|Wiktionary|www.wiktionary.org
2|Wikimedia Commons|commons.wikimedia.org|commons
2|Wikidata|www.wikidata.org
2|Britannica|www.britannica.com
2|Merriam-Webster|www.merriam-webster.com|mw
2|Cambridge Dictionary|dictionary.cambridge.org|cambridge dictionary
2|Oxford Learner's Dictionaries|www.oxfordlearnersdictionaries.com|oxford dictionary
2|Dictionary.com|www.dictionary.com
2|Thesaurus.com|www.thesaurus.com
2|Urban Dictionary|www.urbandictionary.com|ud
2|Linguee|www.linguee.com|linguee.de
2|LEO|dict.leo.org|leo.org,leo dictionary|de,at
2|dict.cc|www.dict.cc|dictcc|de,at,ch
2|Duden|www.duden.de||de,at,ch
2|PONS|de.pons.com|pons.com|de,at
2|WordReference|www.wordreference.com
2|Reverso|www.reverso.net
2|Duolingo|www.duolingo.com
2|Babbel|my.babbel.com|babbel.com
2|Memrise|www.memrise.com
2|Anki|ankiweb.net|ankiweb
2|Quizlet|quizlet.com
2|Khan Academy|www.khanacademy.org|khan
2|Coursera|www.coursera.org
2|edX|www.edx.org
2|Udemy|www.udemy.com
2|Skillshare|www.skillshare.com
2|LinkedIn Learning|www.linkedin.com/learning|lynda
2|MasterClass|www.masterclass.com
2|Brilliant|brilliant.org
2|Codecademy|www.codecademy.com
2|Pluralsight|app.pluralsight.com|pluralsight.com
2|Frontend Masters|frontendmasters.com
2|Egghead|egghead.io
2|MIT OpenCourseWare|ocw.mit.edu|mit ocw
2|TED|www.ted.com|ted talks
2|arXiv|arxiv.org
2|Semantic Scholar|www.semanticscholar.org
2|ResearchGate|www.researchgate.net
2|PubMed|pubmed.ncbi.nlm.nih.gov|pubmed
2|JSTOR|www.jstor.org
2|Zotero|www.zotero.org
2|Mendeley|www.mendeley.com
2|Overleaf|www.overleaf.com|latex
2|Desmos|www.desmos.com/calculator|desmos
2|GeoGebra|www.geogebra.org
2|Symbolab|www.symbolab.com
2|Chegg|www.chegg.com
2|Course Hero|www.coursehero.com
2|Project Gutenberg|www.gutenberg.org|gutenberg
2|Open Library|openlibrary.org
2|Libby|libbyapp.com|libby
2|Moodle|moodle.org
2|Canvas|www.instructure.com/canvas|canvas lms
2|Blackboard|www.blackboard.com
2|National Geographic|www.nationalgeographic.com|natgeo
2|NASA|www.nasa.gov
2|Smithsonian|www.si.edu|smithsonian
2|Our World in Data|ourworldindata.org|owid
2|Statista|www.statista.com
2|Worldometer|www.worldometers.info
2|Time and Date|www.timeanddate.com|time zones
2|World Time Buddy|www.worldtimebuddy.com
2|Calculator.net|www.calculator.net
2|Unit Converter|www.unitconverters.net
2|Snopes|www.snopes.com
2|Instructables|www.instructables.com
2|iFixit|www.ifixit.com
2|WikiHow|www.wikihow.com
2|Scribd|www.scribd.com
2|SlideShare|www.slideshare.net
2|Issuu|issuu.com
2|Instapaper|www.instapaper.com
2|Readwise|readwise.io|readwise reader,read.readwise.io
2|Feedly|feedly.com
2|Inoreader|www.inoreader.com
2|Raindrop.io|app.raindrop.io|raindrop.io,raindrop
2|Pinboard|pinboard.in
2|Kindle|read.amazon.com|kindle cloud reader
2|Blinkist|www.blinkist.com
2|Kobo|www.kobo.com
# Austria: news and media
1|Der Standard|www.derstandard.at|standard,ds|at
1|ORF|orf.at|orf|at
2|ORF News|orf.at/news|news.orf.at|at
2|ORF ON|on.orf.at|orf tvthek,tvthek.orf.at,orf on|at
2|ORF Sound|sound.orf.at|orf radio,radiothek|at
2|ORF Sport|sport.orf.at|orf sport|at
2|ORF Wetter|wetter.orf.at||at
2|Ö3|oe3.orf.at|oe3,hitradio ö3|at
2|Ö1|oe1.orf.at|oe1|at
2|FM4|fm4.orf.at||at
1|Krone|www.krone.at|kronen zeitung,krone,kronenzeitung|at
2|Kurier|kurier.at||at
2|Die Presse|www.diepresse.com|presse|at
2|Salzburger Nachrichten|www.sn.at|sn|at
2|Kleine Zeitung|www.kleinezeitung.at|kleine|at
2|Heute|www.heute.at||at
2|oe24|www.oe24.at|österreich|at
2|profil|www.profil.at||at
2|Falter|www.falter.at||at
2|Wiener Zeitung|www.wienerzeitung.at||at
2|Tiroler Tageszeitung|www.tt.com|tt|at
2|OÖ Nachrichten|www.nachrichten.at|ooen,oön|at
2|Vorarlberger Nachrichten|www.vn.at|vol.at|at
2|NÖN|www.noen.at|noen|at
2|Bezirksblätter|www.meinbezirk.at|meinbezirk|at
2|Puls 24|www.puls24.at|puls24|at
2|ServusTV|www.servustv.com|servus tv|at,de
2|Puls 4|www.puls4.com|puls4|at
2|ATV|www.atv.at||at
2|ZackZack|zackzack.at||at
2|Exxpress|exxpress.at||at
2|Dossier|www.dossier.at||at
2|Datum|datum.at||at
2|Trend|www.trend.at||at
2|News.at|www.news.at||at
2|Der Pragmaticus|www.derpragmaticus.com|pragmaticus|at
2|APA|apa.at|apa ots,ots.at|at
2|Moment|www.moment.at||at
2|Wienerin|www.wienerin.at||at
2|Woman|www.woman.at||at
2|Vienna.at|www.vienna.at||at
2|1000things|www.1000things.at|1000 things|at
2|Falstaff|www.falstaff.com|falstaff.at,falstaff|at,de
# Austria: shopping, classifieds and services
1|willhaben|www.willhaben.at|wh|at
2|Shpock|www.shpock.com||at,uk
2|Billa|shop.billa.at|billa.at,billa|at
2|Spar|www.spar.at|interspar,eurospar|at
2|Hofer|www.hofer.at||at
2|Penny|www.penny.at||at
2|MPreis|www.mpreis.at||at
2|Gurkerl|www.gurkerl.at||at
2|Unimarkt|www.unimarkt.at||at
2|BIPA|www.bipa.at||at
2|Müller|www.mueller.at|mueller.de,müller drogerie|at,de
2|XXXLutz|www.xxxlutz.at|xxxlutz.de,lutz|at,de
2|Möbelix|www.moebelix.at|mobelix|at
2|Mömax|www.moemax.at||at
2|OBI|www.obi.at|obi.de|at,de
2|Hornbach|www.hornbach.at|hornbach.de|at,de
2|Bauhaus|www.bauhaus.at|bauhaus.info|at,de
2|Lagerhaus|www.lagerhaus.at||at
2|Hervis|www.hervis.at||at
2|Intersport|www.intersport.at|intersport.de|at,de
2|Libro|www.libro.at||at
2|Thalia|www.thalia.at|thalia.de|at,de
2|Morawa|www.morawa.at||at
2|Electronic4you|www.electronic4you.at|e4you|at
2|Universal|www.universal.at||at
2|Otto Österreich|www.ottoversand.at||at
2|Peek & Cloppenburg|www.peek-cloppenburg.at|p&c|at,de
2|Humanic|www.humanic.net||at
2|Deichmann|www.deichmann.com||at,de
2|Julius Meinl|www.meinlamgraben.at|meinl am graben|at
2|Shöpping|www.shoepping.at|shopping.at|at
2|Hartlauer|www.hartlauer.at||at
2|Pagro|www.pagro.at||at
2|Fielmann|www.fielmann.at|fielmann.de|at,de
2|Herold|www.herold.at|gelbe seiten|at
2|Das Telefonbuch|www.dastelefonbuch.de||de
# Austria: banks and money
1|George|george.sparkasse.at|george,erste bank,sparkasse.at,erstebank.at|at
2|Erste Bank|www.sparkasse.at/erstebank|erste group,erstegroup.com|at
2|Raiffeisen|www.raiffeisen.at|rlb,mein elba,elba|at
2|Bank Austria|www.bankaustria.at|unicredit bank austria|at
2|BAWAG|www.bawag.at|bawag psk,bawagpsk.com|at
2|easybank|www.easybank.at||at
2|Volksbank Österreich|www.volksbank.at||at
2|Oberbank|www.oberbank.at||at
2|BKS Bank|www.bks.at||at
2|Hypo NOE|www.hyponoe.at||at
2|Dadat|www.dadat.at||at
2|Bank99|www.bank99.at||at
2|FinanzOnline|finanzonline.bmf.gv.at|finanzonline,fon,bmf.gv.at|at
2|Durchblicker|durchblicker.at||at
2|Wiener Städtische|www.wienerstaedtische.at||at
2|UNIQA|www.uniqa.at||at
2|Generali|www.generali.at|generali.com|at,it
2|Allianz|www.allianz.at|allianz.de,allianz.com|at,de
2|Arbeiterkammer|www.arbeiterkammer.at|ak|at
2|WKO|www.wko.at|wirtschaftskammer|at
2|AMS|www.ams.at|eams,arbeitsmarktservice|at
2|Österreichische Post|www.post.at|post|at
2|Statistik Austria|www.statistik.at||at
2|OeNB|www.oenb.at|nationalbank|at
2|Wiener Börse|www.wienerborse.at|wiener boerse|at
# Austria: government and public services
1|oesterreich.gv.at|www.oesterreich.gv.at|help.gv.at,österreich gv|at
2|ID Austria|www.oesterreich.gv.at/id-austria.html|id austria,handysignatur,a-trust|at
2|ELGA|www.gesundheit.gv.at|elga.gv.at|at
2|meineSV|www.meinesv.at|sozialversicherung,sv|at
2|ÖGK|www.gesundheitskasse.at|oegk|at
2|SVS|www.svs.at||at
2|Pensionsversicherung|www.pv.at|pva|at
2|Stadt Wien|www.wien.gv.at|wien gv,mein wien|at
2|Stadt Graz|www.graz.at||at
2|Stadt Linz|www.linz.at||at
2|Stadt Salzburg|www.stadt-salzburg.at||at
2|Stadt Innsbruck|www.innsbruck.gv.at||at
2|Parlament|www.parlament.gv.at||at
2|RIS|www.ris.bka.gv.at|rechtsinformationssystem|at
2|Bundeskanzleramt|www.bundeskanzleramt.gv.at|bka|at
2|USP|www.usp.gv.at|unternehmensserviceportal|at
2|Austria.info|www.austria.info||at
2|Wien Tourismus|www.wien.info||at
2|Wien Energie|www.wienenergie.at||at
2|Wiener Netze|www.wienernetze.at||at
2|EVN|www.evn.at||at
2|Verbund|www.verbund.com|verbund.at|at
2|Energie AG|www.energieag.at||at
2|Kelag|www.kelag.at||at
2|E-Control|www.e-control.at|tarifkalkulator|at
2|aWATTar|www.awattar.at||at
2|ÖAMTC|www.oeamtc.at|oamtc|at
2|ARBÖ|www.arboe.at|arbo|at
2|ASFINAG|www.asfinag.at|vignette,digitale vignette|at
# Austria: transport and travel
1|ÖBB|www.oebb.at|oebb,öbb tickets,tickets.oebb.at,scotty|at
2|Westbahn|westbahn.at|westbahn|at
2|Wiener Linien|www.wienerlinien.at|wl|at
2|WienMobil|www.wienmobil.at|wienmobil|at
2|Linz AG Linien|www.linzag.at||at
2|VOR|www.vor.at|verkehrsverbund ost-region|at
2|VVT|www.vvt.at||at
2|Klimaticket|www.klimaticket.at||at
2|Flughafen Wien|www.viennaairport.com|vie airport,flughafen wien|at
2|CAT|www.cityairporttrain.com|city airport train|at
2|Nightjet|www.nightjet.com||at,de
2|Regiojet|www.regiojet.com||cz,at
2|Bergfex Ski|www.bergfex.at/oesterreich|bergfex ski|at
2|Urlaub am Bauernhof|www.urlaubambauernhof.at||at
2|Alpenverein|www.alpenverein.at|öav|at
2|Naturfreunde|www.naturfreunde.at||at
2|Wikiloc|www.wikiloc.com
# Austria: telecom, jobs, housing, culture
2|A1|www.a1.net|a1 telekom,mein a1|at
2|Magenta|www.magenta.at|t-mobile austria|at
2|Drei|www.drei.at|3|at
2|HoT|www.hot.at|hofer telekom|at
2|spusu|www.spusu.at||at
2|yesss!|www.yesss.at||at
2|bob|www.bob.at||at
2|ORF-Beitrag|orf-beitrag.at|gis,rundfunkbeitrag,orf beitrag|at
2|karriere.at|www.karriere.at|karriere|at
2|StepStone Österreich|www.stepstone.at||at
2|Hokify|hokify.at|hokify|at
2|Jobs.at|www.jobs.at||at
2|ImmoScout24 Österreich|www.immobilienscout24.at|immoscout at|at
2|Immowelt Österreich|www.immowelt.at||at
2|Wohnnet|www.wohnnet.at||at
2|Wiener Wohnen|www.wienerwohnen.at||at
2|Wohnberatung Wien|wohnberatung-wien.at|wohnberatung|at
2|oeticket|www.oeticket.com|ö-ticket,oe-ticket|at
2|Wiener Staatsoper|www.wiener-staatsoper.at|staatsoper|at
2|Wiener Konzerthaus|konzerthaus.at|konzerthaus|at
2|Musikverein|www.musikverein.at||at
2|Burgtheater|www.burgtheater.at||at
2|Albertina|www.albertina.at||at
2|Belvedere|www.belvedere.at||at
2|Kunsthistorisches Museum|www.khm.at|khm|at
2|MuseumsQuartier|www.mqw.at|mq|at
2|Salzburger Festspiele|www.salzburgerfestspiele.at||at
2|Cineplexx|www.cineplexx.at||at
2|Votivkino|www.votivkino.at||at
2|Uni Wien|www.univie.ac.at|univie,universität wien,u:space|at
2|TU Wien|www.tuwien.at|tuwien.ac.at,tiss|at
2|WU Wien|www.wu.ac.at|wu|at
2|Uni Graz|www.uni-graz.at||at
2|TU Graz|www.tugraz.at||at
2|Uni Innsbruck|www.uibk.ac.at|uibk|at
2|JKU Linz|www.jku.at|jku|at
2|Uni Salzburg|www.plus.ac.at||at
2|BOKU|boku.ac.at|boku|at
2|MedUni Wien|www.meduniwien.ac.at||at
2|FH Technikum Wien|www.technikum-wien.at||at
2|Studo|studo.com|studo|at,de
2|ÖH|www.oeh.ac.at|öh|at
2|Lieferservice.at|www.lieferservice.at||at
# Germany
1|Spiegel|www.spiegel.de|der spiegel,spon|de,at
1|Tagesschau|www.tagesschau.de|ard tagesschau|de
2|Zeit Online|www.zeit.de|die zeit,zeit|de,at
2|Süddeutsche Zeitung|www.sueddeutsche.de|sz|de
2|FAZ|www.faz.net|frankfurter allgemeine|de
2|Bild|www.bild.de||de
2|Welt|www.welt.de|die welt|de
2|Handelsblatt|www.handelsblatt.com||de
2|Stern|www.stern.de||de
2|Focus|www.focus.de|focus online|de
2|n-tv|www.n-tv.de|ntv|de
2|taz|taz.de|die tageszeitung|de
2|Der Tagesspiegel|www.tagesspiegel.de|tagesspiegel|de
2|t-online|www.t-online.de|tonline|de
2|ZDF|www.zdf.de|zdf mediathek|de,at
2|ARD Mediathek|www.ardmediathek.de|ard|de,at
2|Arte|www.arte.tv||de,fr,at
2|3sat|www.3sat.de||de,at,ch
2|Deutschlandfunk|www.deutschlandfunk.de|dlf|de
2|ProSieben|www.prosieben.de|pro7|de,at
2|RTL|www.rtl.de||de
2|Chip|www.chip.de||de,at
2|Stiftung Warentest|www.test.de|warentest|de,at
2|Finanztip|www.finanztip.de||de
2|Deutsche Bahn|www.bahn.de|db,db navigator,bahn|de,at
2|BVG|www.bvg.de||de
2|MVG|www.mvg.de||de
2|ADAC|www.adac.de||de
2|DHL|www.dhl.de|dhl.com,dhl paket|de,at
2|Hermes|www.myhermes.de|hermes|de
2|DPD|www.dpd.com|dpd.at,dpd.de|de,at
2|GLS|gls-group.com|gls-group.eu,gls|de,at
2|UPS|www.ups.com
2|FedEx|www.fedex.com
2|Deutsche Post|www.deutschepost.de||de
2|ELSTER|www.elster.de||de
2|Bund.de|www.bund.de||de
2|Bundesagentur für Arbeit|www.arbeitsagentur.de|arbeitsagentur|de
2|Telekom|www.telekom.de|t-mobile.de,deutsche telekom|de
2|Vodafone|www.vodafone.de|vodafone.com|de
2|O2|www.o2online.de|o2|de
2|1&1|www.1und1.de||de
2|Verivox|www.verivox.de||de
2|ImmoScout24|www.immobilienscout24.de|immoscout,immoscout24|de
2|Immowelt|www.immowelt.de||de
2|WG-Gesucht|www.wg-gesucht.de|wg gesucht|de,at
2|StepStone|www.stepstone.de||de
2|Indeed Deutschland|de.indeed.com|indeed de|de
2|Mobile.de|www.mobile.de||de
2|AutoScout24|www.autoscout24.com|autoscout24.de,autoscout24.at,autoscout24|de,at,eu
2|Gebrauchtwagen.at|www.gebrauchtwagen.at||at
2|Doctolib|www.doctolib.de|doctolib.fr,doctolib|de,fr
2|Jameda|www.jameda.de||de
2|DocFinder|www.docfinder.at||at
2|Shop Apotheke|www.shop-apotheke.at|shop-apotheke.com|at,de
2|DocMorris|www.docmorris.de||de
2|Rewe|shop.rewe.de|rewe.de,rewe|de
2|Edeka|www.edeka.de||de
2|Kaufland|www.kaufland.de|kaufland.at|de,at
2|Netto|www.netto-online.de||de
2|Picnic|picnic.app|picnic|de,nl
2|Knuspr|www.knuspr.de||de
2|Eventim|www.eventim.de|eventim.at,ticketmaster.de|de,at
2|Kino.de|www.kino.de||de
2|Moviepilot|www.moviepilot.de||de
2|Fernsehserien.de|www.fernsehserien.de||de
# Switzerland
2|SRF|www.srf.ch|srf play|ch
2|NZZ|www.nzz.ch|neue zürcher zeitung|ch,at,de
2|Tages-Anzeiger|www.tagesanzeiger.ch|tagi|ch
2|20 Minuten|www.20min.ch|20min|ch
2|Blick|www.blick.ch||ch
2|Watson|www.watson.ch|watson.de|ch,de
2|SBB|www.sbb.ch|sbb mobile|ch
2|Swisscom|www.swisscom.ch||ch
2|Sunrise|www.sunrise.ch||ch
2|Salt|www.salt.ch||ch
2|Migros|www.migros.ch||ch
2|Coop|www.coop.ch||ch
2|Digitec|www.digitec.ch||ch
2|Ricardo|www.ricardo.ch||ch
2|Tutti|www.tutti.ch||ch
2|Homegate|www.homegate.ch||ch
2|comparis|www.comparis.ch||ch
2|ch.ch|www.ch.ch||ch
2|Die Post Schweiz|www.post.ch||ch
2|ETH Zürich|ethz.ch|ethz,eth|ch
2|Local.ch|www.local.ch||ch
2|search.ch|www.search.ch||ch
2|Liechtenstein Landesverwaltung|www.llv.li||li
# Gaming
1|Steam|store.steampowered.com|steampowered.com,steam store,steamcommunity.com
2|Epic Games Store|store.epicgames.com|epicgames.com,epic games,egs
2|GOG|www.gog.com
2|itch.io|itch.io|itch
2|PlayStation|www.playstation.com|psn,ps5
2|Nintendo|www.nintendo.com|nintendo eshop
2|Xbox Cloud Gaming|www.xbox.com/play|xcloud
2|GeForce NOW|play.geforcenow.com|geforce now,gfn
2|Battle.net|battle.net|blizzard,battlenet
2|EA|www.ea.com|electronic arts
2|Ubisoft|www.ubisoft.com
2|Riot Games|www.riotgames.com|league of legends
2|Roblox|www.roblox.com
2|Minecraft|www.minecraft.net
2|IGN|www.ign.com
2|GameSpot|www.gamespot.com
2|Polygon|www.polygon.com
2|Kotaku|kotaku.com
2|PC Gamer|www.pcgamer.com
2|Eurogamer|www.eurogamer.net
2|Metacritic|www.metacritic.com
2|HowLongToBeat|howlongtobeat.com|hltb
2|SteamDB|steamdb.info
2|ProtonDB|www.protondb.com
2|Nexus Mods|www.nexusmods.com
2|Humble Bundle|www.humblebundle.com
2|Instant Gaming|www.instant-gaming.com
2|GameStop|www.gamestop.com||us
2|Wordle|www.nytimes.com/games/wordle|nyt wordle
2|NYT Games|www.nytimes.com/crosswords|nyt crossword,nyt connections
2|GeoGuessr|www.geoguessr.com
2|Speedrun.com|www.speedrun.com
2|Board Game Arena|boardgamearena.com|bga
2|BoardGameGeek|boardgamegeek.com|bgg
# Jobs, housing and cars (international, US, UK)
1|Indeed|www.indeed.com
2|LinkedIn Jobs|www.linkedin.com/jobs|linkedin jobs
2|Monster|www.monster.com
2|ZipRecruiter|www.ziprecruiter.com||us
2|Upwork|www.upwork.com
2|Fiverr|www.fiverr.com
2|Toptal|www.toptal.com
2|Malt|www.malt.com|malt.de,malt.fr|fr,de,eu
2|Freelancer|www.freelancer.com
2|We Work Remotely|weworkremotely.com|wwr
2|Remote OK|remoteok.com|remoteok
2|Welcome to the Jungle|app.welcometothejungle.com|otta.com,otta,wttj
2|Zillow|www.zillow.com||us
2|Redfin|www.redfin.com||us
2|Realtor.com|www.realtor.com||us
2|Rightmove|www.rightmove.co.uk|rightmove|uk
2|Zoopla|www.zoopla.co.uk|zoopla|uk
2|SpareRoom|www.spareroom.co.uk|spareroom|uk
2|Idealista|www.idealista.com|idealista.it,idealista.pt|es,it,pt
2|Funda|www.funda.nl|funda|nl
2|Leboncoin|www.leboncoin.fr|leboncoin|fr
2|SeLoger|www.seloger.com||fr
2|Subito|www.subito.it||it
2|Marktplaats|www.marktplaats.nl|marktplaats|nl
2|2dehands|www.2dehands.be|2ememain.be|be
2|Blocket|www.blocket.se|blocket|se
2|Finn.no|www.finn.no|finn|no
2|DBA|www.dba.dk||dk
2|Tori|www.tori.fi||fi
2|OLX|www.olx.pl|olx.pt,olx.ro,olx.com,olx|pl,pt,ro
2|Wallapop|es.wallapop.com|wallapop.com,wallapop|es,it
2|Autotrader|www.autotrader.co.uk|autotrader.com|uk,us
2|Cars.com|www.cars.com||us
2|CarGurus|www.cargurus.com||us,uk
2|Carvana|www.carvana.com||us
2|Kelley Blue Book|www.kbb.com|kbb|us
2|Tesla|www.tesla.com
2|PlugShare|www.plugshare.com
2|ABRP|abetterrouteplanner.com|a better routeplanner
# Health and fitness
2|WebMD|www.webmd.com
2|Mayo Clinic|www.mayoclinic.org
2|NHS|www.nhs.uk|nhs app|uk
2|Healthline|www.healthline.com
2|Drugs.com|www.drugs.com
2|NetDoktor|www.netdoktor.at|netdoktor.de,netdoktor|at,de
2|Gesund.bund.de|gesund.bund.de||de
2|MyFitnessPal|www.myfitnesspal.com|mfp
2|Garmin Connect|connect.garmin.com|garmin connect,garmin.com
2|Fitbit|www.fitbit.com
2|Oura|cloud.ouraring.com|ouraring.com,oura ring
2|Whoop|app.whoop.com|whoop.com
2|Peloton|www.onepeloton.com|peloton
2|Zwift|www.zwift.com
2|Headspace|www.headspace.com
2|Calm|www.calm.com
2|Zocdoc|www.zocdoc.com||us
2|23andMe|www.23andme.com
2|Cronometer|cronometer.com
2|Yazio|www.yazio.com||de,at
2|Urban Sports Club|urbansportsclub.com|usc,urban sports|de,at,eu
2|ClassPass|classpass.com
2|Eversports|www.eversports.at|eversports.com,eversports|at,de
2|Runtastic|www.runtastic.com|runtastic,adidas running|at
2|Freeletics|www.freeletics.com||de
# Government and public services (US, UK, EU)
2|USA.gov|www.usa.gov||us
2|USPS|www.usps.com||us
2|Social Security|www.ssa.gov|social security administration|us
2|Medicare|www.medicare.gov||us
2|Healthcare.gov|www.healthcare.gov||us
2|US Passports|travel.state.gov|passport.gov|us
2|ESTA|esta.cbp.dhs.gov|esta application
2|GOV.UK|www.gov.uk||uk
2|Royal Mail|www.royalmail.com||uk
2|National Rail|www.nationalrail.co.uk|national rail|uk
2|TfL|tfl.gov.uk|tfl,transport for london|uk
2|Companies House|find-and-update.company-information.service.gov.uk|companies house|uk
2|European Union|european-union.europa.eu|europa.eu,eu|eu
2|European Parliament|www.europarl.europa.eu|europarl|eu
2|EUR-Lex|eur-lex.europa.eu|eurlex|eu
2|Eurostat|ec.europa.eu/eurostat|eurostat|eu
2|EPO|www.epo.org|european patent office|eu
2|EUIPO|euipo.europa.eu|euipo,tmview|eu
2|Your Europe|europa.eu/youreurope|youreurope|eu
2|ECB|www.ecb.europa.eu|ecb,european central bank|eu
2|United Nations|www.un.org|un
2|WHO|www.who.int|world health organization
2|World Bank|www.worldbank.org
2|OECD|www.oecd.org
2|Schengen Visa Info|www.schengenvisainfo.com
# France, Benelux
2|France Info|www.francetvinfo.fr|franceinfo|fr
2|France TV|www.france.tv|francetv|fr
2|TF1|www.tf1info.fr|tf1.fr,tf1|fr
2|Ouest-France|www.ouest-france.fr||fr
2|20 Minutes|www.20minutes.fr||fr
2|SNCF Connect|www.sncf-connect.com|sncf,oui.sncf|fr
2|RATP|www.ratp.fr||fr
2|Service-Public.fr|www.service-public.fr||fr
2|impots.gouv.fr|www.impots.gouv.fr|impots|fr
2|Ameli|www.ameli.fr|ameli|fr
2|La Poste|www.laposte.fr||fr
2|Orange|www.orange.fr|orange.com|fr
2|Free|www.free.fr||fr
2|SFR|www.sfr.fr||fr
2|Carrefour|www.carrefour.fr|carrefour.com|fr
2|Leroy Merlin|www.leroymerlin.fr||fr
2|Allociné|www.allocine.fr|allocine|fr
2|VRT NWS|www.vrt.be/vrtnws|vrt nws|be
2|RTBF|www.rtbf.be||be
2|Het Nieuwsblad|www.nieuwsblad.be||be
2|De Standaard|www.standaard.be||be
2|Le Soir|www.lesoir.be||be
2|NMBS SNCB|www.belgiantrain.be|nmbs,sncb|be
2|NS|www.ns.nl|nederlandse spoorwegen|nl
2|9292|9292.nl||nl
2|Albert Heijn|www.ah.nl|albert heijn|nl
2|Jumbo|www.jumbo.com||nl
2|DigiD|www.digid.nl||nl
2|Belastingdienst|www.belastingdienst.nl||nl
2|NU.nl|www.nu.nl||nl
2|De Telegraaf|www.telegraaf.nl||nl
2|NPO Start|npo.nl/start|npo|nl
2|Tweakers|tweakers.net||nl,be
2|PostNL|www.postnl.nl||nl
2|Luxembourg Times|www.luxtimes.lu||lu
# Italy, Spain, Portugal
2|ANSA|www.ansa.it||it
2|Il Sole 24 Ore|www.ilsole24ore.com|sole 24 ore|it
2|La Stampa|www.lastampa.it||it
2|Gazzetta dello Sport|www.gazzetta.it|gazzetta|it
2|RaiPlay|www.raiplay.it|rai|it
2|Mediaset Infinity|mediasetinfinity.mediaset.it|mediaset|it
2|Trenitalia|www.trenitalia.com||it
2|Italo|www.italotreno.com|italotreno.it,italo treno|it
2|Poste Italiane|www.poste.it||it
2|Agenzia delle Entrate|www.agenziaentrate.gov.it||it
2|INPS|www.inps.it||it
2|TIM|www.tim.it||it
2|Esselunga|www.esselunga.it||it
2|ePrice|www.eprice.it||it
2|RTVE|www.rtve.es||es
2|ABC España|www.abc.es||es
2|La Vanguardia|www.lavanguardia.com||es
2|Marca|www.marca.com||es
2|AS|as.com||es
2|Renfe|www.renfe.com||es
2|Agencia Tributaria|sede.agenciatributaria.gob.es|agenciatributaria.gob.es|es
2|Correos|www.correos.es||es
2|El Corte Inglés|www.elcorteingles.es||es
2|Mercadona|www.mercadona.es||es
2|Movistar|www.movistar.es||es
2|Público|www.publico.pt||pt
2|Expresso|expresso.pt||pt
2|RTP|www.rtp.pt||pt
2|CP|www.cp.pt|comboios de portugal|pt
2|Portal das Finanças|www.portaldasfinancas.gov.pt||pt
# Nordics, Central and Eastern Europe
2|SVT|www.svt.se|svt play,svtplay.se|se
2|Aftonbladet|www.aftonbladet.se||se
2|Dagens Nyheter|www.dn.se||se
2|SJ|www.sj.se||se
2|Skatteverket|www.skatteverket.se||se
2|NRK|www.nrk.no||no
2|VG|www.vg.no||no
2|Vy|www.vy.no||no
2|DR|www.dr.dk||dk
2|Politiken|politiken.dk||dk
2|DSB|www.dsb.dk||dk
2|borger.dk|www.borger.dk||dk
2|Yle|yle.fi||fi
2|Helsingin Sanomat|www.hs.fi||fi
2|VR|www.vr.fi||fi
2|Gazeta Wyborcza|wyborcza.pl||pl
2|Onet|www.onet.pl||pl
2|WP.pl|www.wp.pl||pl
2|PKP Intercity|www.intercity.pl||pl
2|iDNES|www.idnes.cz||cz
2|Seznam|www.seznam.cz||cz
2|České dráhy|www.cd.cz||cz
2|Alza|www.alza.cz|alza.at,alza.de,alza|cz,sk,at
2|Index.hu|index.hu||hu
2|Telex|telex.hu||hu
2|SME|www.sme.sk||sk
2|24ur|www.24ur.com||si
2|Index.hr|www.index.hr||hr
2|Kathimerini|www.ekathimerini.com||gr
2|Hürriyet|www.hurriyet.com.tr||tr
2|Ukrainska Pravda|www.pravda.com.ua||ua
# Rest of the world
2|Globo|www.globo.com|g1|br
2|UOL|www.uol.com.br||br
2|Folha de S.Paulo|www.folha.uol.com.br|folha|br
2|Clarín|www.clarin.com||ar
2|El Universal|www.eluniversal.com.mx||mx
2|NDTV|www.ndtv.com||in
2|Paytm|paytm.com||in
2|IRCTC|www.irctc.co.in|irctc|in
2|JioHotstar|www.jiohotstar.com|hotstar.com,hotstar|in
2|Yahoo Japan|www.yahoo.co.jp||jp
2|Mercari|jp.mercari.com|mercari.com|jp,us
2|Niconico|www.nicovideo.jp|nico nico|jp
2|Pixiv|www.pixiv.net||jp
2|Bilibili|www.bilibili.com||cn
2|Zhihu|www.zhihu.com||cn
2|Douyin|www.douyin.com||cn
2|Daum|www.daum.net||kr
2|Seek|www.seek.com.au||au
2|Domain|www.domain.com.au||au
2|realestate.com.au|www.realestate.com.au||au
2|Stuff|www.stuff.co.nz||nz
2|Trade Me|www.trademe.co.nz|trademe|nz
2|News24|www.news24.com||za
2|Takealot|www.takealot.com||za
2|Jumia|www.jumia.com.ng|jumia|ng,ke
2|Noon|www.noon.com||ae,sa
2|Kijiji|www.kijiji.ca|kijiji|ca
2|Canada.ca|www.canada.ca||ca
2|Australia.gov.au|my.gov.au|mygov|au
# Utilities and everyday tools
2|Temp Mail|temp-mail.org|temporary email
2|Pastebin|pastebin.com
2|QR Code Generator|www.qr-code-generator.com|qr code
2|Bitly|bitly.com|bit.ly
2|TinyURL|tinyurl.com
2|Convertio|convertio.co|file converter
2|CloudConvert|cloudconvert.com
2|Online-Convert|www.online-convert.com
2|PDF Candy|pdfcandy.com
2|Rentry|rentry.co
2|Strawpoll|strawpoll.com
2|Random.org|www.random.org
2|Unicode Table|symbl.cc|unicode,emoji table
2|Emojipedia|emojipedia.org|emoji
2|Typing Test|monkeytype.com|monkeytype
2|Keybr|www.keybr.com
2|Zoom Test|zoom.us/test|zoom test
2|WebRTC Test|test.webrtc.org
2|BuiltWith|builtwith.com
2|Wappalyzer|www.wappalyzer.com
2|Who.is|who.is|whois
2|ICANN Lookup|lookup.icann.org|icann whois
2|ipinfo|ipinfo.io
2|Shodan|www.shodan.io
2|crt.sh|crt.sh|certificate transparency
2|Google Safe Browsing|transparencyreport.google.com/safe-browsing/search|safe browsing check
2|Find My|www.icloud.com/find|find my iphone
2|Google Find My Device|www.google.com/android/find|find my device
2|Samsung Find|smartthingsfind.samsung.com|samsung find
2|Samsung|www.samsung.com
2|Sony|www.sony.com
2|LG|www.lg.com
2|Dell|www.dell.com
2|HP|www.hp.com
2|Lenovo|www.lenovo.com
2|Logitech|www.logitech.com|logi
2|Bose|www.bose.com
2|Sonos|www.sonos.com
2|Philips Hue|www.philips-hue.com|hue
2|OnePlus|www.oneplus.com
2|Xiaomi|www.mi.com|xiaomi
2|Raspberry Pi|www.raspberrypi.com
2|Arduino|www.arduino.cc
2|Home Assistant|www.home-assistant.io|hass
2|Ring|ring.com
2|Google Home|home.google.com|nest,nest.com
2|Alexa|alexa.amazon.com|amazon alexa
"""#
}
