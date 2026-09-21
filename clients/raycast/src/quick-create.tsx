import { ActionPanel, Form, FormValidation, Icon, showToast, Toast, useNavigation } from "@raycast/api";
import { useFetch, useForm } from "@raycast/utils";
import { useEffect, useState } from "react";
import { parseLeadingTime, TimeParseError } from "@remotealarm/core";
import type { SoundTone } from "@remotealarm/core";
import {
  formatAge,
  RAMP_OPTIONS,
  showDispatchToast,
  showWarning,
  SOUND_TONES,
  summarizeDevices,
  useClient,
  useDevices,
  useSettings,
} from "./lib";

interface QuickCreateValues {
  query: string;
  tone: string;
  ramp: string;
}

export default function QuickCreateCommand() {
  const client = useClient();
  const { pop } = useNavigation();
  const { data: settings, isLoading: settingsLoading } = useSettings(client);
  const { data: devices } = useDevices(client);
  const summary = summarizeDevices(devices);

  const [preview, setPreview] = useState<{ interpretation: string; label: string } | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [defaultsSet, setDefaultsSet] = useState(false);

  const { handleSubmit, itemProps, values, setValue } = useForm<QuickCreateValues>({
    initialValues: {
      query: "",
      tone: settings?.sound_tone ?? "alarm",
      ramp: String(settings?.ramp_seconds ?? 30),
    },
    validation: {
      query: FormValidation.Required,
      tone: FormValidation.Required,
      ramp: FormValidation.Required,
    },
    onSubmit: async (formValues) => {
      const trimmed = formValues.query.trim();
      const leading = parseLeadingTime(trimmed);
      if (!leading) {
        setParseError("Could not find a time in that sentence. Try '25m Oven'.");
        return;
      }
      const label = leading.rest.trim() || "Alarm";

      try {
        const result = await client.createAlarm({
          label,
          targetTime: leading.parsed.targetTime,
          repeat_days:
            leading.parsed.repeatDays.length > 0 ? leading.parsed.repeatDays : undefined,
          sound_tone: formValues.tone as SoundTone,
          ramp_seconds: Number(formValues.ramp),
        });
        await showDispatchToast(result, "Created");
        if (summary.noDevices) {
          await showWarning("No devices registered — this alarm won't ring.");
        } else if (summary.stale) {
          await showWarning("Phone last pinged over 24 hours ago.");
        }
        pop();
      } catch (err) {
        await showToast({
          title: "Remote Alarm",
          message: err instanceof Error ? err.message : String(err),
          style: Toast.Style.Failure,
        });
      }
    },
  });

  useEffect(() => {
    if (settings && !defaultsSet) {
      setValue("tone", settings.sound_tone);
      setValue("ramp", String(settings.ramp_seconds));
      setDefaultsSet(true);
    }
  }, [settings, defaultsSet, setValue]);

  useEffect(() => {
    const trimmed = values.query.trim();
    if (!trimmed) {
      setPreview(null);
      setParseError(null);
      return;
    }
    try {
      const leading = parseLeadingTime(trimmed);
      if (leading) {
        setPreview({
          interpretation: leading.parsed.interpretation,
          label: leading.rest.trim() || "Alarm",
        });
        setParseError(null);
      } else {
        setPreview(null);
        setParseError("Could not parse a time. Try '25m Oven' or 'tomorrow 6pm Call mum'.");
      }
    } catch (err) {
      setPreview(null);
      setParseError(err instanceof TimeParseError ? err.message : String(err));
    }
  }, [values.query]);

  return (
    <Form
      isLoading={settingsLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Alarm" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField
        title="Alarm"
        placeholder="25m Oven, tomorrow 6pm Call mum, weekdays 7am Walk…"
        info="Type the time first, then the label."
        {...itemProps.query}
      />
      {preview && (
        <Form.Description
          title="Resolved time"
          text={`${preview.interpretation}${preview.label ? ` · Label: ${preview.label}` : ""}`}
        />
      )}
      {parseError && !preview && (
        <Form.Description title="Preview" text={parseError} />
      )}
      <Form.Dropdown title="Tone" {...itemProps.tone}>
        {SOUND_TONES.map((tone) => (
          <Form.Dropdown.Item key={tone} value={tone} title={tone} />
        ))}
      </Form.Dropdown>
      <Form.Dropdown title="Ramp" {...itemProps.ramp}>
        {RAMP_OPTIONS.map((ramp) => (
          <Form.Dropdown.Item key={ramp} value={String(ramp)} title={`${ramp}s`} />
        ))}
      </Form.Dropdown>
      {summary.noDevices && (
        <Form.Description
          title="Reachability"
          text="No devices registered — this alarm won't ring."
        />
      )}
      {!summary.noDevices && summary.stale && summary.ageMs !== null && (
        <Form.Description
          title="Reachability"
          text={`Phone last pinged ${formatAge(summary.ageMs)} ago.`}
        />
      )}
    </Form>
  );
}
