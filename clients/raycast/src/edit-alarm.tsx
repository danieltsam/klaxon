import {
  ActionPanel,
  Form,
  FormValidation,
  getPreferenceValues,
  Icon,
  LaunchProps,
  List,
  showToast,
  Toast,
  useNavigation,
} from "@raycast/api";
import { useFetch, useForm } from "@raycast/utils";
import { useMemo } from "react";
import { toLocalDate } from "@remotealarm/core";
import type { Alarm, SoundTone } from "@remotealarm/core";
import {
  daysFromRecurrenceValue,
  ErrorEmptyView,
  formatAge,
  RAMP_OPTIONS,
  RECURRENCE_OPTIONS,
  recurrenceValueFromDays,
  showDispatchToast,
  showWarning,
  SOUND_TONES,
  summarizeDevices,
  useClient,
  useDevices,
} from "./lib";

interface EditAlarmValues {
  label: string;
  description: string;
  datetime: Date | null;
  recurrence: string;
  tone: string;
  ramp: string;
}

interface EditAlarmProps {
  alarm: Alarm;
}

function EditAlarmForm({ alarm }: EditAlarmProps) {
  const client = useClient();
  const { pop } = useNavigation();
  const { data: devices } = useDevices(client);
  const summary = summarizeDevices(devices);

  const recurrenceValue = recurrenceValueFromDays(alarm.repeat_days);
  const recurrenceOptions = useMemo(() => {
    const options = [...RECURRENCE_OPTIONS];
    if (recurrenceValue.startsWith("custom:")) {
      options.push({
        label: "Custom",
        key: recurrenceValue,
        days: alarm.repeat_days ?? [],
      });
    }
    return options;
  }, [alarm.repeat_days, recurrenceValue]);

  const { handleSubmit, itemProps } = useForm<EditAlarmValues>({
    initialValues: {
      label: alarm.label,
      description: alarm.description ?? "",
      datetime: toLocalDate(alarm),
      recurrence: recurrenceValue,
      tone: alarm.sound_tone ?? "alarm",
      ramp: String(alarm.ramp_seconds ?? 30),
    },
    validation: {
      label: FormValidation.Required,
      datetime: FormValidation.Required,
      recurrence: FormValidation.Required,
      tone: FormValidation.Required,
      ramp: FormValidation.Required,
    },
    onSubmit: async (formValues) => {
      try {
        const result = await client.updateAlarm(alarm.id, {
          label: formValues.label,
          targetTime: formValues.datetime ?? new Date(),
          description: formValues.description || undefined,
          repeat_days: daysFromRecurrenceValue(formValues.recurrence),
          sound_tone: formValues.tone as SoundTone,
          ramp_seconds: Number(formValues.ramp),
        });
        await showDispatchToast(result, "Updated");
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

  return (
    <Form
      actions={
        <ActionPanel>
          <Action.SubmitForm title="Save Changes" onSubmit={handleSubmit} />
        </ActionPanel>
      }
    >
      <Form.TextField title="Label" {...itemProps.label} />
      <Form.TextField title="Description" {...itemProps.description} />
      <Form.DatePicker
        title="Date & Time"
        type={Form.DatePicker.Type.DateTime}
        {...itemProps.datetime}
      />
      <Form.Dropdown title="Recurrence" {...itemProps.recurrence}>
        {recurrenceOptions.map((opt) => (
          <Form.Dropdown.Item key={opt.key} value={opt.key} title={opt.label} />
        ))}
      </Form.Dropdown>
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

export function EditAlarm({ alarm }: { alarm?: Alarm }) {
  if (!alarm) {
    return (
      <Form>
        <Form.Description title="Alarm not found" text="The alarm could not be loaded." />
      </Form>
    );
  }
  return <EditAlarmForm alarm={alarm} />;
}

export default function EditAlarmCommand(props: LaunchProps<{ arguments: { id: string } }>) {
  const client = useClient();
  const prefs = getPreferenceValues<Preferences>();
  const { data: alarms, isLoading, error } = useFetch<Alarm[]>(
    async () => client.listAlarms("all"),
    { execute: true }
  );
  const alarm = alarms?.find((a) => a.id === props.arguments.id);

  if (error && !isLoading) {
    return (
      <List isLoading={isLoading} navigationTitle="Remote Alarm">
        <ErrorEmptyView error={error} backendUrl={prefs.backendUrl} />
      </List>
    );
  }

  if (isLoading) {
    return <Form isLoading={true} />;
  }

  return <EditAlarm alarm={alarm} />;
}
