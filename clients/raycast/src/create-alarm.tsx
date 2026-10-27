import {
  ActionPanel,
  Form,
  FormValidation,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useForm } from "@raycast/utils";
import { useEffect, useState } from "react";
import type { SoundTone } from "@remotealarm/core";
import {
  daysFromRecurrenceValue,
  formatAge,
  INTERVAL_OPTIONS,
  RAMP_OPTIONS,
  RECURRENCE_OPTIONS,
  showDispatchToast,
  showWarning,
  SOUND_TONES,
  summarizeDevices,
  useClient,
  useDevices,
  useSettings,
} from "./lib";

interface CreateAlarmValues {
  label: string;
  description: string;
  datetime: Date | null;
  recurrence: string;
  interval: string;
  tone: string;
  ramp: string;
}

export default function CreateAlarmCommand() {
  const client = useClient();
  const { pop } = useNavigation();
  const { data: settings, isLoading: settingsLoading } = useSettings(client);
  const { data: devices } = useDevices(client);
  const summary = summarizeDevices(devices);
  const [defaultsSet, setDefaultsSet] = useState(false);

  const { handleSubmit, itemProps, setValue } = useForm<CreateAlarmValues>({
    initialValues: {
      label: "",
      description: "",
      datetime: new Date(),
      recurrence: "once",
      interval: "1",
      tone: settings?.sound_tone ?? "alarm",
      ramp: String(settings?.ramp_seconds ?? 30),
    },
    validation: {
      label: FormValidation.Required,
      datetime: FormValidation.Required,
      recurrence: FormValidation.Required,
      interval: FormValidation.Required,
      tone: FormValidation.Required,
      ramp: FormValidation.Required,
    },
    onSubmit: async (formValues) => {
      try {
        const repeatDays = daysFromRecurrenceValue(formValues.recurrence);
        const result = await client.createAlarm({
          label: formValues.label,
          targetTime: formValues.datetime ?? new Date(),
          description: formValues.description || undefined,
          repeat_days: repeatDays,
          sound_tone: formValues.tone as SoundTone,
          ramp_seconds: Number(formValues.ramp),
          // A one-time alarm has no cadence to stretch.
          recurrence_interval_weeks:
            repeatDays && formValues.interval === "2" ? 2 : undefined,
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

  return (
    <Form
      isLoading={settingsLoading}
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Create Alarm" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField title="Label" placeholder="Oven" {...itemProps.label} />
      <Form.TextField
        title="Description"
        placeholder="Optional extra detail"
        {...itemProps.description}
      />
      <Form.DatePicker
        title="Date & Time"
        type={Form.DatePicker.Type.DateTime}
        {...itemProps.datetime}
      />
      <Form.Dropdown title="Recurrence" {...itemProps.recurrence}>
        {RECURRENCE_OPTIONS.map((opt) => (
          <Form.Dropdown.Item key={opt.key} value={opt.key} title={opt.label} />
        ))}
      </Form.Dropdown>
      <Form.Dropdown title="Interval" {...itemProps.interval}>
        {INTERVAL_OPTIONS.map((opt) => (
          <Form.Dropdown.Item
            key={opt.value}
            value={opt.value}
            title={opt.label}
          />
        ))}
      </Form.Dropdown>
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
