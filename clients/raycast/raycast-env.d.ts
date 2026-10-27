/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Backend URL - The URL of your Klaxon backend (homelab or tailnet). The scheme is optional; http:// is assumed. */
  "backendUrl": string,
  /** Confirm destructive actions - Show a confirmation alert before cancelling an alarm. */
  "confirmDestructive": boolean
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `list-alarms` command */
  export type ListAlarms = ExtensionPreferences & {}
  /** Preferences accessible in the `quick-create` command */
  export type QuickCreate = ExtensionPreferences & {}
  /** Preferences accessible in the `create-alarm` command */
  export type CreateAlarm = ExtensionPreferences & {}
  /** Preferences accessible in the `device-status` command */
  export type DeviceStatus = ExtensionPreferences & {}
  /** Preferences accessible in the `test-connection` command */
  export type TestConnection = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `list-alarms` command */
  export type ListAlarms = {}
  /** Arguments passed to the `quick-create` command */
  export type QuickCreate = {}
  /** Arguments passed to the `create-alarm` command */
  export type CreateAlarm = {}
  /** Arguments passed to the `device-status` command */
  export type DeviceStatus = {}
  /** Arguments passed to the `test-connection` command */
  export type TestConnection = {}
}

