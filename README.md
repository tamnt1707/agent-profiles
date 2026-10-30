# Agent Profiles

**Run Claude Code with any AI provider, each one in its own profile.**

English · [Tiếng Việt](README.vi.md)

<p align="center">
  <img src="docs/images/main-dark.png" alt="Agent Profiles: a list of profiles on the left, with a dot for each one, and the settings of the selected profile on the right" width="760">
</p>

Claude Code can work with many AI providers, not only one. The catch is that every
provider needs its own address, its own key and its own model names, and switching between
them usually means editing settings by hand or keeping a pile of scripts.

Agent Profiles turns each provider into a **profile** you can create in a minute. Every
profile gets its own command. Type `claude-work-glm` in any terminal and you are working
with that provider. Type `claude-side-deepseek` and you are working with another one. Your
keys stay safe, and your normal Claude Code setup is never touched.

Claude Code is the CLI it runs today. Other agents can be added later, which is why the app is
called Agent Profiles.

## What you get

- **One profile per provider.** Give it a name, an address, a key and a model. Done.
- **A terminal inside the app.** Open a profile and its terminal is right in the window, with tabs
  (*New session*, *Restart session*, *Close session*). A profile keeps running while you look at
  another one, and the sidebar marks the ones that run. A new tab asks how to start: *Normal*, or as an
  orchestrator (see below). Prefer Terminal or iTerm2? Switch in the settings.
- **One command per profile.** The command is named after the profile (you can rename it)
  and works from any terminal, in any folder.
- **Ready-made templates** for your Claude subscription (no address and no key, you just sign in),
  OpenRouter, DeepSeek, Kimi, GLM, MiniMax, Xiaomi MiMo and a local proxy. Pick one and the
  address fills itself in.
- **A dot that tells you if it works.** The app asks the CLI for one short answer, the way your own
  command does, and tells you what is wrong: the key, the address, the model name, the sign-in or the
  network. The result is kept between runs, so you see the state of every profile as soon as you open
  the app, and *Test connection* only refreshes it.
- **Keys kept in the macOS Keychain.** Your keys are never saved in a plain file.
- **Your own Claude Code stays as it is.** Each profile keeps its own settings and history,
  so nothing leaks from one to another. If you like, you can share your instructions, skills
  and agents across all of them.
- **Orchestration kit.** One button adds a set of subagents (scout, researcher, builder, tester,
  reviewer, committer) and the instructions for the main session to one profile, so a strong model
  can plan while cheaper ones do the reading and the typing. Nothing outside that profile is touched.
  Two workflows, each drawn as a diagram in the app: *Sequential* (the orchestrator hands out one step at a
  time) and *Queue* (coders merge into a task branch once lint and format pass, a secretary writes the queue,
  the tester follows it in order, and nothing goes to a higher branch until everything is green). The queue
  workflow adds `frontend-2d`, `frontend-3d`, `backend` and `secretary`. Reinstalling updates the agents in
  place with a `.bak` backup and removes the ones the kit has dropped.
- **Start as an orchestrator.** In the Terminal tab, pick *Orchestrator* when you open a tab: Claude starts
  with Opus at medium effort and the instructions of the workflow, for that session only. Missing agents are
  installed first, and `CLAUDE.md` is not touched.
- **Heartbeat for your 5 hour window.** Pick the times (and days) at which the app sends one tiny `ping`
  through a profile's CLI, so the usage window of your subscription starts when you want it to. It runs even
  when the app is closed, and shows you when the last ping went out and how it ended.
- **Your own Claude Code is in the list too.** *Default* (your `~/.claude`) sits under the profiles the app
  created, with a terminal, usage and the same dot. It can never be deleted from the app.
- **A launcher in the menu bar.** Open any profile in one click, in its own folder or in one of the
  five you used last.
- **Token usage per profile.** See today, the last 7 days and all time, counted on your Mac from the
  profile's own history, with an optional price per million tokens for a cost estimate.
- **Pick the model from a list.** Type any model name, or choose from the ones your provider
  offers.
- **Clean removal.** Delete a profile (from its row too) and everything that belongs to it goes with it.
- **English and Vietnamese**, with a light or dark look that follows your Mac.
- **Updates itself.** The app tells you when a new version is out and installs it with one
  click, after checking that it really comes from us.

<p align="center">
  <img src="docs/images/terminal-dark.png" alt="A profile running Claude Code in the terminal inside the window" width="760">
</p>

<p align="center">
  <img src="docs/images/main-light.png" alt="The same window in the light theme" width="560">
  &nbsp;
  <img src="docs/images/settings-en.png" alt="The settings window: language, theme, terminal, connection checks and updates" width="230">
</p>

## Install

You need a Mac with **Apple Silicon** running **macOS 14 or later**.

1. Download the latest `Agent-Profiles-<version>.dmg` from the
   [Releases page](https://github.com/tamnt1707/agent-profiles/releases/latest).
2. Open it and drag **Agent Profiles** into **Applications**.
3. The first time, right-click the app and choose **Open**. macOS asks once because the app is
   not notarized by Apple yet.

Coming from **Claude Profiles 0.2.0**? Download this version by hand once, because the old app cannot
update itself to a differently named app, then delete the old `Claude Profiles.app`. Your profiles, keys
and commands carry over as they are.

## Get started in three steps

1. Click **+**, pick the CLI and a provider template (or start from scratch) and type a name.
2. Paste your key and click **Test connection**. Then **Save**.
3. Open the **Terminal** tab, or click **Open in terminal**, or type the profile's command in any terminal.

When you save your first profile, the app offers to make the commands work in every terminal.
It asks first, and you can undo it at any time from the settings.

## Questions

**Is my key safe?**
Your key is stored in the macOS Keychain, the same place your Mac keeps passwords. It is never
written to a file, and it is sent only to the address you typed for that profile.

**Will it change how my normal Claude Code works?**
No. Your own Claude Code settings are left alone. Each profile has a separate space of its own.

**Which providers can I use?**
Any provider that offers a Claude-compatible address. The templates cover the popular ones, and
you can type any other address by hand. Or use your Claude subscription: pick that template and sign in the
first time you open the profile.

**Which CLIs does it support?**
Claude Code for now. The app looks for the CLIs that are installed on your Mac when you create a profile.
Others are planned.

**Where is my data?**
In `~/.claude-profiles` (profiles, launchers, one config folder per profile) and the macOS Keychain (keys). The
folder keeps the name the app had at first, so nothing had to move when it was renamed.

**What does *Test connection* cost?**
One short request through the CLI: about 1,500 tokens in and a few out. The app also does it once for a profile
that has no result yet when it starts; the result is kept until the profile changes or you check again. You can
turn the check at start off in Settings.

**What happens when I delete a profile?**
Its key, its command and its saved history are all removed. If it was your last profile, the app
also offers to remove the terminal setup it added.

**Does it work on an Intel Mac?**
Not yet. The app runs on Apple Silicon only.

## More

- [What is new in each version](CHANGELOG.md)
- [Building the app yourself](docs/BUILDING.md)

Agent Profiles is an independent project. It is not made by, or affiliated with, Anthropic or
any of the providers it can connect to. All product names belong to their owners.
