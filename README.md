# Remote Alarm

A self-hosted remotely manageable Alarm app for Android phones. I run the backend myself, and I can set, trigger, and manage alarms on my phone from my workstation or any other device that can set network requests to my backend.

## Why I made this

I find regular reminders do not work well for me. They blend into normal notifications, and it's very easy for me to miss them.

I prefer a more abrasive solution in alarms. A good alarm tone is pain-inducing, borderline upsetting and interrupts whatever I am doing.

The problem is where I set them. I want the flexibility to set alarms from my laptop or desktop, not just from the phone (ideally using Raycast!). The less I touch my phone, the better.

## Why I did not use something else

I could not find an existing service that does this.

- Proper alarm functionality on apps like TickTick or Todoist are gated by a paywall.
- notify.sh, and Pushover can send notifications, but they cannot set a real Android alarm that takes over the phone screen and continues ringing till I silence it.
- [Galarm](https://www.galarmapp.com/) is close to what I want, but it is closed-source and requires an enterprise plan for API access. I cannot hook it into my own scripts.

## What it does

- Sets real alarms on an Android phone. They use the full screen and override silent mode.
- Lets me set, change, snooze, and cancel alarms from my workstation.
- Runs a web dashboard and exposes an API.
- I mostly use the API and write my own scripts, including a Raycast extension.

## How it works

- An Android app, written in Flutter.
- A self-hosted backend. It has the API, the web dashboard, and the database of my alarms.
- Firebase Cloud Messaging, to deliver the alarms to the phone. This rides on Google Play services, which most phones already run.

Everything runs on my private Tailscale network. I don't have to expose any port to the internet.

### Phones without Google Play services

FCM depends on Google Play services. If a phone does not have them, this project cannot deliver alarms to that phone reliably.
