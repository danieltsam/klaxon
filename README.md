# Remote Alarm

A self-hosted alarm system for Android phones. I run the backend myself, and I set, trigger, and manage alarms on my phone from my workstation.

## Why I made this

Regular reminders do not work well for me. They blend into normal notifications, so I miss them.

Alarms work better. The alarm tone interrupts whatever I am doing and is hard to ignore. That small amount of stress is what makes me stop and do the task.

The problem is where I set them. I usually want to set and manage alarms from my laptop or desktop, not from the phone. The less I touch my phone, the better. So I wanted alarms that I can control from my main workstation.

## Why I did not use something else

I could not find an existing service that does this.

- TickTick, notify.sh, and Pushover can send notifications, but they cannot set a real Android alarm that takes over the phone.
- Galarm is close to what I want, but it is closed. I cannot hook it into my own scripts.
- I like to build my own workflows and tools on my machines, so a closed service was not going to work.

## What it does

- Sets real alarms on an Android phone. They use the full screen and override silent mode.
- Lets me set, change, snooze, and cancel alarms from my workstation.
- Runs a web dashboard and exposes an API.
- I mostly use the API and write my own scripts, including a Raycast extension.

## How it works

- An Android app, written in Flutter. This is my first Flutter app.
- A self-hosted backend. It has the API, the web dashboard, and the alarm store.
- Firebase Cloud Messaging, to deliver the alarms to the phone. This rides on Google Play services, which most phones already run.

Everything runs on my private Tailscale network. I do not expose any port to the internet.

### Phones without Google Play services

FCM depends on Google Play services. If a phone does not have them, this project cannot deliver alarms to that phone reliably.

## Status

Personal project. It works for me. It is also my first Flutter app.
