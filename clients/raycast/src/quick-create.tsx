import {
  Action,
  ActionPanel,
  Form,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useForm } from "@raycast/utils";
import { useEffect, useState } from "react";
import { parseLeadingTime, TimeParseError } from "@remotealarm/core";
import type { SoundTone } from "@remotealarm/core";
import { formatRecurrence, requiredField } from "./lib";
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

  const [preview, setPreview] = useState<{
    interpretation: string;
    label: string;
    recurrence: string;
    tone?: string;
    ramp?: number;
    note?: string;
  } | null>(null);
  const [parseError, setParseError] = useState<string | null>(null);
  const [defaultsSet, setDefaultsSet] = useState(false);

  const { handleSubmit, itemProps, values, setValue } =
    useForm<QuickCreateValues>({
      initialValues: {
        query: "",
        tone: settings?.sound_tone ?? "alarm",
        ramp: String(settings?.ramp_seconds ?? 30),
      },
      validation: {
        query: requiredField,
        tone: requiredField,
        ramp: requiredField,
      },
      onSubmit: async (formValues) => {
        const trimmed = formValues.query.trim();
        // A confident `already_passed` refusal (e.g. a passed `this friday`) is a
        // handled error here, never an unhandled rejection from the submit path.
        let leading: ReturnType<typeof parseLeadingTime>;
        try {
          leading = parseLeadingTime(trimmed);
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err);
          setParseError(message);
          await showToast({
            title: "Klaxon",
            message,
            style: Toast.Style.Failure,
          });
          return;
        }
        if (!leading) {
          setParseError(
            "Could not find a time in that sentence. Try '25m Oven'.",
          );
          return;
        }
        const label = leading.rest.trim() || "Alarm";
        const parsed = leading.parsed;

        // The parser resolves an interval; the backend stores weeks 1 or 2 only.
        // Refuse the rest rather than creating a silently one-time alarm.
        if (parsed.interval) {
          const { count, unit } = parsed.interval;
          if (unit === "days" || count < 1 || count > 2) {
            const message = `Cannot store every ${count} ${unit}: only weekly or fortnightly recurrence.`;
            setParseError(message);
            await showToast({
              title: "Klaxon",
              message,
              style: Toast.Style.Failure,
            });
            return;
          }
        }
        const meta = parsed.alarm ?? {};

        try {
          const result = await client.createAlarm({
            label,
            targetTime: parsed.targetTime,
            repeat_days:
              parsed.repeatDays.length > 0 ? parsed.repeatDays : undefined,
            // The sentence is more specific than the form defaults, so it wins
            // when it names a tone, ramp or note.
            sound_tone: (meta.sound_tone ?? formValues.tone) as SoundTone,
            ramp_seconds: meta.ramp_seconds ?? Number(formValues.ramp),
            description: meta.description,
            recurrence_interval_weeks: parsed.interval
              ? (parsed.interval.count as 1 | 2)
              : undefined,
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
            title: "Klaxon",
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
          recurrence: leading.parsed.interval
            ? `every ${leading.parsed.interval.count} ${leading.parsed.interval.unit}`
            : leading.parsed.repeatDays.length > 0
              ? formatRecurrence(leading.parsed.repeatDays)
              : "one-time",
          tone: leading.parsed.alarm?.sound_tone,
          ramp: leading.parsed.alarm?.ramp_seconds,
          note: leading.parsed.alarm?.description,
        });
        setParseError(null);
      } else {
        setPreview(null);
        setParseError(
          "Could not parse a time. Try '25m Oven' or 'tomorrow 6pm Call mum'.",
        );
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
      {preview && (
        <Form.Description
          title="Repeats"
          text={`${preview.recurrence}${preview.tone ? ` · tone ${preview.tone}` : ""}${preview.ramp !== undefined ? ` · ramp ${preview.ramp}s` : ""}`}
        />
      )}
      {preview?.note && <Form.Description title="Note" text={preview.note} />}
      <Form.Dropdown title="Tone" {...itemProps.tone}>
        {SOUND_TONES.map((tone) => (
          <Form.Dropdown.Item key={tone} value={tone} title={tone} />
        ))}
      </Form.Dropdown>
      <Form.Dropdown title="Ramp" {...itemProps.ramp}>
        {RAMP_OPTIONS.map((ramp) => (
          <Form.Dropdown.Item
            key={ramp}
            value={String(ramp)}
            title={`${ramp}s`}
          />
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
