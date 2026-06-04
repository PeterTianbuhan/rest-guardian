package me.petertian.restguardian;

import android.Manifest;
import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public final class MainActivity extends Activity {
    static final String PREFS = "rest_guardian_settings";
    static final String KEY_WORK_MINUTES = "workMinutes";
    static final String KEY_REST_MINUTES = "restMinutes";
    static final String KEY_MAX_WORK_MINUTES = "maxWorkMinutes";

    private EditText workMinutesField;
    private EditText restMinutesField;
    private EditText maxWorkMinutesField;
    private TextView permissionStatus;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        buildUi();
    }

    @Override
    protected void onResume() {
        super.onResume();
        updatePermissionStatus();
    }

    private void buildUi() {
        SharedPreferences prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setGravity(Gravity.CENTER_HORIZONTAL);
        root.setPadding(dp(22), dp(28), dp(22), dp(22));
        root.setBackgroundColor(Color.rgb(18, 18, 18));
        setContentView(root);

        TextView title = text("反向番茄钟", 28, true);
        title.setTextColor(Color.WHITE);
        root.addView(title, matchWrap());

        TextView subtitle = text("手机先做 Android MVP：悬浮倒计时、小球拖动、休息遮罩。", 15, false);
        subtitle.setTextColor(Color.rgb(200, 200, 200));
        subtitle.setPadding(0, dp(8), 0, dp(20));
        root.addView(subtitle, matchWrap());

        permissionStatus = text("", 14, true);
        permissionStatus.setTextColor(Color.rgb(255, 210, 120));
        permissionStatus.setPadding(0, 0, 0, dp(14));
        root.addView(permissionStatus, matchWrap());

        workMinutesField = numberField(prefs.getInt(KEY_WORK_MINUTES, 25));
        restMinutesField = numberField(prefs.getInt(KEY_REST_MINUTES, 5));
        maxWorkMinutesField = numberField(prefs.getInt(KEY_MAX_WORK_MINUTES, 50));

        root.addView(settingRow("下一轮工作", workMinutesField));
        root.addView(settingRow("最短休息", restMinutesField));
        root.addView(settingRow("连续工作上限", maxWorkMinutesField));

        Button saveButton = button("保存设置");
        saveButton.setOnClickListener(v -> saveSettings());
        root.addView(saveButton, buttonLayout());

        Button overlayPermissionButton = button("允许悬浮窗权限");
        overlayPermissionButton.setOnClickListener(v -> openOverlayPermission());
        root.addView(overlayPermissionButton, buttonLayout());

        Button notificationPermissionButton = button("允许通知权限");
        notificationPermissionButton.setOnClickListener(v -> requestNotificationPermission());
        root.addView(notificationPermissionButton, buttonLayout());

        Button startButton = button("启动守卫");
        startButton.setOnClickListener(v -> startGuardian());
        root.addView(startButton, buttonLayout());

        Button stopButton = button("停止守卫");
        stopButton.setOnClickListener(v -> stopService(new Intent(this, GuardianService.class)));
        root.addView(stopButton, buttonLayout());

        TextView note = text("小球：按住拖动，双击展开。休息满最短时间后，自己选择是否回到工作。", 14, false);
        note.setTextColor(Color.rgb(190, 190, 190));
        note.setPadding(0, dp(16), 0, 0);
        root.addView(note, matchWrap());
    }

    private boolean saveSettings() {
        Integer work = readMinutes(workMinutesField);
        Integer rest = readMinutes(restMinutesField);
        Integer maxWork = readMinutes(maxWorkMinutesField);
        if (work == null || rest == null || maxWork == null) {
            toast("请输入有效分钟数。");
            return false;
        }
        if (work < 1 || work > 50 || maxWork < 1 || maxWork > 50) {
            toast("工作时间和连续工作上限都不能超过 50 分钟。");
            return false;
        }
        if (rest < 5 || rest > 120) {
            toast("最短休息需要在 5 到 120 分钟之间。");
            return false;
        }
        if (maxWork < work) {
            toast("连续工作上限不能小于下一轮工作时间。");
            return false;
        }

        getSharedPreferences(PREFS, MODE_PRIVATE)
            .edit()
            .putInt(KEY_WORK_MINUTES, work)
            .putInt(KEY_REST_MINUTES, rest)
            .putInt(KEY_MAX_WORK_MINUTES, maxWork)
            .apply();
        toast("已保存。设置会在下一轮工作生效。");
        return true;
    }

    private void startGuardian() {
        if (!Settings.canDrawOverlays(this)) {
            toast("先允许悬浮窗权限。");
            openOverlayPermission();
            return;
        }
        if (!saveSettings()) {
            return;
        }
        Intent intent = new Intent(this, GuardianService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent);
        } else {
            startService(intent);
        }
    }

    private void openOverlayPermission() {
        Intent intent = new Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:" + getPackageName())
        );
        startActivity(intent);
    }

    private void requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33
            && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[] { Manifest.permission.POST_NOTIFICATIONS }, 10);
        } else {
            toast("通知权限已经可用。");
        }
    }

    private void updatePermissionStatus() {
        boolean overlay = Settings.canDrawOverlays(this);
        boolean notification = Build.VERSION.SDK_INT < 33
            || checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED;
        permissionStatus.setText("悬浮窗：" + (overlay ? "已允许" : "未允许") + "    通知：" + (notification ? "已允许" : "未允许"));
    }

    private LinearLayout settingRow(String title, EditText field) {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        row.setGravity(Gravity.CENTER_VERTICAL);
        row.setPadding(0, dp(8), 0, dp(8));

        TextView label = text(title, 16, true);
        label.setTextColor(Color.WHITE);
        row.addView(label, new LinearLayout.LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1));
        row.addView(field, new LinearLayout.LayoutParams(dp(92), ViewGroup.LayoutParams.WRAP_CONTENT));

        TextView unit = text("分钟", 14, false);
        unit.setTextColor(Color.rgb(190, 190, 190));
        unit.setPadding(dp(10), 0, 0, 0);
        row.addView(unit, new LinearLayout.LayoutParams(ViewGroup.LayoutParams.WRAP_CONTENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return row;
    }

    private EditText numberField(int value) {
        EditText field = new EditText(this);
        field.setText(String.valueOf(value));
        field.setTextColor(Color.WHITE);
        field.setGravity(Gravity.CENTER);
        field.setInputType(InputType.TYPE_CLASS_NUMBER);
        field.setSingleLine(true);
        return field;
    }

    private Integer readMinutes(EditText field) {
        try {
            return Integer.parseInt(field.getText().toString().trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private TextView text(String value, int sp, boolean bold) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        if (bold) {
            view.setTypeface(view.getTypeface(), android.graphics.Typeface.BOLD);
        }
        return view;
    }

    private Button button(String title) {
        Button button = new Button(this);
        button.setText(title);
        button.setAllCaps(false);
        return button;
    }

    private LinearLayout.LayoutParams buttonLayout() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
        params.topMargin = dp(10);
        return params;
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }
}
