package me.petertian.restguardian;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.GestureDetector;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

public final class GuardianService extends Service {
    private static final String CHANNEL_ID = "rest_guardian";
    private static final int NOTIFICATION_ID = 1207;
    private static final int HARD_MAX_WORK_MINUTES = 50;
    private static final String KEY_BUBBLE_X = "bubbleX";
    private static final String KEY_BUBBLE_Y = "bubbleY";
    private static final String KEY_COMPACT = "compact";

    private enum Mode {
        WORK,
        PAUSE,
        REST
    }

    private final Handler handler = new Handler(Looper.getMainLooper());
    private final Runnable ticker = new Runnable() {
        @Override
        public void run() {
            tick();
            handler.postDelayed(this, 1000);
        }
    };

    private WindowManager windowManager;
    private SharedPreferences settings;
    private SharedPreferences state;

    private View timerView;
    private WindowManager.LayoutParams timerParams;
    private View restOverlayView;
    private TextView modeLabel;
    private TextView timerLabel;
    private Button addMinuteButton;
    private Button pauseButton;
    private TextView restElapsedLabel;
    private TextView restSuggestionLabel;
    private Button returnToWorkButton;

    private Mode mode = Mode.WORK;
    private boolean compact = false;
    private int workSeconds;
    private int restSeconds;
    private int maxWorkSeconds;
    private int remainingSeconds;
    private int continuousWorkSeconds;
    private int currentWorkBaseSeconds;
    private int manualWorkExtensionSeconds;
    private int restElapsedSeconds;
    private int pauseElapsedSeconds;
    private int restSuggestionIndex;
    private long lastTickRealtimeMillis;

    private final String[] restSuggestions = new String[] {
        "离开屏幕，去当五分钟线下人类。",
        "给水杯一个被使用的机会。",
        "去厕所也算高质量中断。",
        "抬头看远处，别让眼睛继续加班。",
        "站起来伸个懒腰，身体不是外设。",
        "什么都不做也可以，大脑需要清缓存。",
        "在房间里走一圈，证明你还会离开椅子。",
        "把肩膀放下来，别一直端着。",
        "去窗边看看，外面的世界还在加载。",
        "现在的任务：不操作任何电子设备。"
    };

    @Override
    public void onCreate() {
        super.onCreate();
        windowManager = (WindowManager) getSystemService(WINDOW_SERVICE);
        settings = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
        state = getSharedPreferences("rest_guardian_runtime", MODE_PRIVATE);
        createNotificationChannel();
        startForeground(NOTIFICATION_ID, buildNotification("守卫运行中"));

        if (!Settings.canDrawOverlays(this)) {
            Toast.makeText(this, "缺少悬浮窗权限。", Toast.LENGTH_SHORT).show();
            stopSelf();
            return;
        }

        loadConfig();
        compact = state.getBoolean(KEY_COMPACT, false);
        startWork(workSeconds);
        showTimerOverlay();
        lastTickRealtimeMillis = SystemClock.elapsedRealtime();
        handler.postDelayed(ticker, 1000);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        return START_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        handler.removeCallbacks(ticker);
        removeTimerOverlay();
        removeRestOverlay();
        super.onDestroy();
    }

    private void loadConfig() {
        int workMinutes = clamp(settings.getInt(MainActivity.KEY_WORK_MINUTES, 25), 1, HARD_MAX_WORK_MINUTES);
        int restMinutes = clamp(settings.getInt(MainActivity.KEY_REST_MINUTES, 5), 5, 120);
        int maxWorkMinutes = clamp(settings.getInt(MainActivity.KEY_MAX_WORK_MINUTES, 50), workMinutes, HARD_MAX_WORK_MINUTES);
        workSeconds = workMinutes * 60;
        restSeconds = restMinutes * 60;
        maxWorkSeconds = maxWorkMinutes * 60;
    }

    private void startWork(int seconds) {
        loadConfig();
        mode = Mode.WORK;
        remainingSeconds = Math.max(1, seconds);
        currentWorkBaseSeconds = remainingSeconds;
        continuousWorkSeconds = 0;
        manualWorkExtensionSeconds = 0;
        restElapsedSeconds = 0;
        pauseElapsedSeconds = 0;
        lastTickRealtimeMillis = SystemClock.elapsedRealtime();
        removeRestOverlay();
        updateTimerOverlay();
    }

    private void startPause() {
        if (mode != Mode.WORK) {
            return;
        }
        mode = Mode.PAUSE;
        pauseElapsedSeconds = 0;
        lastTickRealtimeMillis = SystemClock.elapsedRealtime();
        showPauseOverlay();
        updateTimerOverlay();
    }

    private void returnFromPause() {
        if (mode != Mode.PAUSE) {
            return;
        }
        mode = Mode.WORK;
        lastTickRealtimeMillis = SystemClock.elapsedRealtime();
        removeRestOverlay();
        updateTimerOverlay();
    }

    private void startRest() {
        mode = Mode.REST;
        remainingSeconds = 0;
        continuousWorkSeconds = 0;
        restElapsedSeconds = 0;
        pauseElapsedSeconds = 0;
        restSuggestionIndex = 0;
        lastTickRealtimeMillis = SystemClock.elapsedRealtime();
        showRestOverlay();
        updateTimerOverlay();
    }

    private void tick() {
        long now = SystemClock.elapsedRealtime();
        int elapsedSeconds = (int) ((now - lastTickRealtimeMillis) / 1000L);
        if (elapsedSeconds <= 0) {
            return;
        }
        lastTickRealtimeMillis += elapsedSeconds * 1000L;

        if (mode == Mode.WORK) {
            continuousWorkSeconds = Math.min(maxWorkSeconds, continuousWorkSeconds + elapsedSeconds);
            remainingSeconds = Math.max(0, remainingSeconds - elapsedSeconds);
            if (continuousWorkSeconds >= maxWorkSeconds || remainingSeconds == 0) {
                startRest();
                return;
            }
            updateTimerOverlay();
            return;
        }

        if (mode == Mode.PAUSE) {
            pauseElapsedSeconds += elapsedSeconds;
            int recoveredSeconds = elapsedSeconds * 5;
            remainingSeconds = Math.min(maxWorkSeconds, remainingSeconds + recoveredSeconds);
            continuousWorkSeconds = Math.max(0, continuousWorkSeconds - recoveredSeconds);
            updateTimerOverlay();
            updateRestOverlay();
            return;
        }

        int previousRestElapsedSeconds = restElapsedSeconds;
        restElapsedSeconds += elapsedSeconds;
        int suggestionSteps = restElapsedSeconds / 6 - previousRestElapsedSeconds / 6;
        if (suggestionSteps > 0) {
            restSuggestionIndex = (restSuggestionIndex + suggestionSteps) % restSuggestions.length;
        }
        updateTimerOverlay();
        updateRestOverlay();
    }

    private void showTimerOverlay() {
        removeTimerOverlay();
        timerParams = new WindowManager.LayoutParams();
        timerParams.type = WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
        timerParams.format = android.graphics.PixelFormat.TRANSLUCENT;
        timerParams.flags = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
            | WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
        timerParams.gravity = Gravity.TOP | Gravity.START;
        timerParams.width = compact ? dp(112) : expandedTimerWidth();
        timerParams.height = compact ? dp(42) : dp(132);
        timerParams.x = state.getInt(KEY_BUBBLE_X, defaultTimerX(timerParams.width));
        timerParams.y = state.getInt(KEY_BUBBLE_Y, dp(36));

        timerView = compact ? compactTimerView() : expandedTimerView();
        windowManager.addView(timerView, timerParams);
        updateTimerOverlay();
    }

    private View compactTimerView() {
        TextView bubble = text("25:00", 17, true);
        bubble.setGravity(Gravity.CENTER);
        bubble.setTextColor(Color.WHITE);
        bubble.setBackground(rounded(Color.argb(220, 24, 24, 24), dp(21)));
        bubble.setOnTouchListener(new BubbleTouchHandler(true));
        timerLabel = bubble;
        modeLabel = null;
        addMinuteButton = null;
        return bubble;
    }

    private View expandedTimerView() {
        LinearLayout panel = new LinearLayout(this);
        panel.setOrientation(LinearLayout.VERTICAL);
        panel.setPadding(dp(12), dp(10), dp(12), dp(12));
        panel.setBackground(rounded(Color.argb(232, 24, 24, 24), dp(20)));
        panel.setOnTouchListener(new BubbleTouchHandler(false));

        LinearLayout statusRow = new LinearLayout(this);
        statusRow.setOrientation(LinearLayout.HORIZONTAL);
        statusRow.setGravity(Gravity.CENTER_VERTICAL);

        modeLabel = text("工作", 12, true);
        modeLabel.setTextColor(Color.rgb(255, 165, 75));
        statusRow.addView(modeLabel, wrap());

        timerLabel = text("25:00", 28, true);
        timerLabel.setTextColor(Color.WHITE);
        timerLabel.setPadding(dp(10), 0, 0, 0);
        statusRow.addView(timerLabel, wrap());

        panel.addView(statusRow, matchWrap());

        LinearLayout buttonRow = new LinearLayout(this);
        buttonRow.setOrientation(LinearLayout.HORIZONTAL);
        buttonRow.setGravity(Gravity.CENTER);
        buttonRow.setPadding(0, dp(10), 0, 0);

        addMinuteButton = smallButton("+1");
        addMinuteButton.setOnClickListener(v -> addOneMinute());
        buttonRow.addView(addMinuteButton, buttonCell());

        pauseButton = smallButton("暂停");
        pauseButton.setOnClickListener(v -> startPause());
        buttonRow.addView(pauseButton, buttonCell());

        Button restButton = smallButton("休息");
        restButton.setOnClickListener(v -> startRest());
        buttonRow.addView(restButton, buttonCell());

        Button collapseButton = smallButton("收起");
        collapseButton.setOnClickListener(v -> setCompact(true));
        buttonRow.addView(collapseButton, buttonCell());

        Button quitButton = smallButton("×");
        quitButton.setOnClickListener(v -> stopSelf());
        buttonRow.addView(quitButton, buttonCell());

        panel.addView(buttonRow, matchWrap());
        return panel;
    }

    private void setCompact(boolean value) {
        if (compact == value) {
            return;
        }
        compact = value;
        state.edit().putBoolean(KEY_COMPACT, compact).apply();
        showTimerOverlay();
    }

    private void addOneMinute() {
        if (mode != Mode.WORK) {
            return;
        }
        int limit = Math.max(0, maxWorkSeconds - currentWorkBaseSeconds);
        int remainingAllowance = Math.max(0, limit - manualWorkExtensionSeconds);
        if (remainingAllowance < 60) {
            toast("这轮的加时额度用完了，到点就休息。");
            return;
        }
        remainingSeconds += 60;
        manualWorkExtensionSeconds += 60;
        updateTimerOverlay();
    }

    private void showPauseOverlay() {
        removeRestOverlay();
        WindowManager.LayoutParams params = new WindowManager.LayoutParams();
        params.type = WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
        params.format = android.graphics.PixelFormat.TRANSLUCENT;
        params.flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
        params.gravity = Gravity.TOP | Gravity.START;
        params.width = WindowManager.LayoutParams.MATCH_PARENT;
        params.height = WindowManager.LayoutParams.MATCH_PARENT;

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.argb(190, 0, 0, 0));
        root.setClickable(true);

        LinearLayout card = overlayCard("暂停中", Color.rgb(255, 210, 90));
        restSuggestionLabel.setText("每停 1 分钟，工作倒计时补 5 分钟。");

        returnToWorkButton = button("回到工作");
        returnToWorkButton.setOnClickListener(v -> returnFromPause());
        card.addView(returnToWorkButton, matchWrap());

        addCenteredCard(root, card);
        restOverlayView = root;
        windowManager.addView(restOverlayView, params);
        updateRestOverlay();
    }

    private LinearLayout overlayCard(String titleText, int timerColor) {
        LinearLayout card = new LinearLayout(this);
        card.setOrientation(LinearLayout.VERTICAL);
        card.setGravity(Gravity.CENTER_HORIZONTAL);
        card.setPadding(dp(28), dp(28), dp(28), dp(28));
        card.setBackground(rounded(Color.argb(238, 24, 24, 24), dp(18)));

        TextView title = text(titleText, 30, true);
        title.setTextColor(Color.WHITE);
        card.addView(title, wrap());

        restElapsedLabel = text("00:00", 52, true);
        restElapsedLabel.setTextColor(timerColor);
        restElapsedLabel.setPadding(0, dp(12), 0, dp(14));
        card.addView(restElapsedLabel, wrap());

        restSuggestionLabel = text(restSuggestions[0], 16, true);
        restSuggestionLabel.setTextColor(Color.rgb(56, 213, 213));
        restSuggestionLabel.setGravity(Gravity.CENTER);
        restSuggestionLabel.setPadding(0, 0, 0, dp(18));
        card.addView(restSuggestionLabel, matchWrap());

        return card;
    }

    private void addCenteredCard(FrameLayout root, LinearLayout card) {
        FrameLayout.LayoutParams cardParams = new FrameLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT,
            Gravity.CENTER
        );
        int horizontal = dp(22);
        cardParams.leftMargin = horizontal;
        cardParams.rightMargin = horizontal;
        root.addView(card, cardParams);
    }

    private void showRestOverlay() {
        removeRestOverlay();
        WindowManager.LayoutParams params = new WindowManager.LayoutParams();
        params.type = WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY;
        params.format = android.graphics.PixelFormat.TRANSLUCENT;
        params.flags = WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN;
        params.gravity = Gravity.TOP | Gravity.START;
        params.width = WindowManager.LayoutParams.MATCH_PARENT;
        params.height = WindowManager.LayoutParams.MATCH_PARENT;

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.argb(218, 0, 0, 0));
        root.setClickable(true);

        LinearLayout card = overlayCard("休息中", Color.rgb(46, 204, 113));

        returnToWorkButton = button("再休息 05:00 后可回到工作");
        returnToWorkButton.setOnClickListener(v -> {
            if (restElapsedSeconds >= restSeconds) {
                startWork(workSeconds);
            }
        });
        card.addView(returnToWorkButton, matchWrap());

        addCenteredCard(root, card);

        restOverlayView = root;
        windowManager.addView(restOverlayView, params);
        updateRestOverlay();
    }

    private void updateTimerOverlay() {
        if (timerLabel != null) {
            timerLabel.setText(formatTime(mode == Mode.REST ? restElapsedSeconds : remainingSeconds));
        }
        if (modeLabel != null) {
            if (mode == Mode.REST) {
                modeLabel.setText("休息");
                modeLabel.setTextColor(Color.rgb(46, 204, 113));
            } else if (mode == Mode.PAUSE) {
                modeLabel.setText("暂停");
                modeLabel.setTextColor(Color.rgb(255, 210, 90));
            } else {
                modeLabel.setText("工作");
                modeLabel.setTextColor(Color.rgb(255, 165, 75));
            }
        }
        if (addMinuteButton != null) {
            addMinuteButton.setEnabled(mode == Mode.WORK && manualExtensionHeadroom() >= 60);
        }
        if (pauseButton != null) {
            pauseButton.setEnabled(mode == Mode.WORK);
        }
    }

    private void updateRestOverlay() {
        if (restElapsedLabel == null || returnToWorkButton == null) {
            return;
        }
        if (mode == Mode.PAUSE) {
            restElapsedLabel.setText(formatTime(pauseElapsedSeconds));
            restSuggestionLabel.setText(pauseElapsedSeconds >= 60
                ? "已补回 " + (pauseElapsedSeconds * 5 / 60) + " 分钟。想回去随时可以。"
                : "每停 1 分钟，工作倒计时补 5 分钟。");
            returnToWorkButton.setEnabled(true);
            returnToWorkButton.setText("回到工作");
            return;
        }

        restElapsedLabel.setText(formatTime(restElapsedSeconds));
        restSuggestionLabel.setText(restSuggestions[restSuggestionIndex]);

        int remainingRestSeconds = Math.max(0, restSeconds - restElapsedSeconds);
        if (remainingRestSeconds == 0) {
            returnToWorkButton.setEnabled(true);
            returnToWorkButton.setText("已休息够，回到工作");
        } else {
            returnToWorkButton.setEnabled(false);
            returnToWorkButton.setText("再休息 " + formatTime(remainingRestSeconds) + " 后可回到工作");
        }
    }

    private void removeTimerOverlay() {
        if (timerView != null) {
            windowManager.removeView(timerView);
            timerView = null;
            modeLabel = null;
            timerLabel = null;
            addMinuteButton = null;
            pauseButton = null;
        }
    }

    private void removeRestOverlay() {
        if (restOverlayView != null) {
            windowManager.removeView(restOverlayView);
            restOverlayView = null;
            restElapsedLabel = null;
            restSuggestionLabel = null;
            returnToWorkButton = null;
        }
    }

    private int manualExtensionHeadroom() {
        int limit = Math.max(0, maxWorkSeconds - currentWorkBaseSeconds);
        int remainingAllowance = Math.max(0, limit - manualWorkExtensionSeconds);
        int currentRoundHeadroom = Math.max(0, maxWorkSeconds - remainingSeconds);
        return Math.min(remainingAllowance, currentRoundHeadroom);
    }

    private final class BubbleTouchHandler implements View.OnTouchListener {
        private final boolean expandOnDoubleTap;
        private final GestureDetector gestureDetector;
        private float downRawX;
        private float downRawY;
        private int startX;
        private int startY;
        private boolean dragging;

        BubbleTouchHandler(boolean expandOnDoubleTap) {
            this.expandOnDoubleTap = expandOnDoubleTap;
            gestureDetector = new GestureDetector(GuardianService.this, new GestureDetector.SimpleOnGestureListener() {
                @Override
                public boolean onDoubleTap(MotionEvent event) {
                    if (BubbleTouchHandler.this.expandOnDoubleTap) {
                        setCompact(false);
                    }
                    return true;
                }
            });
        }

        @Override
        public boolean onTouch(View view, MotionEvent event) {
            gestureDetector.onTouchEvent(event);
            switch (event.getActionMasked()) {
                case MotionEvent.ACTION_DOWN:
                    downRawX = event.getRawX();
                    downRawY = event.getRawY();
                    startX = timerParams.x;
                    startY = timerParams.y;
                    dragging = false;
                    return true;
                case MotionEvent.ACTION_MOVE:
                    int dx = Math.round(event.getRawX() - downRawX);
                    int dy = Math.round(event.getRawY() - downRawY);
                    if (Math.abs(dx) > dp(3) || Math.abs(dy) > dp(3)) {
                        dragging = true;
                        timerParams.x = startX + dx;
                        timerParams.y = Math.max(0, startY + dy);
                        windowManager.updateViewLayout(timerView, timerParams);
                    }
                    return true;
                case MotionEvent.ACTION_UP:
                case MotionEvent.ACTION_CANCEL:
                    if (dragging) {
                        state.edit()
                            .putInt(KEY_BUBBLE_X, timerParams.x)
                            .putInt(KEY_BUBBLE_Y, timerParams.y)
                            .apply();
                    }
                    return true;
                default:
                    return true;
            }
        }
    }

    private Notification buildNotification(String content) {
        Intent intent = new Intent(this, MainActivity.class);
        PendingIntent pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT
        );
        return new Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle("反向番茄钟")
            .setContentText(content)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build();
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return;
        }
        NotificationChannel channel = new NotificationChannel(
            CHANNEL_ID,
            getString(R.string.notification_channel),
            NotificationManager.IMPORTANCE_LOW
        );
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(channel);
    }

    private Button smallButton(String title) {
        Button button = button(title);
        button.setTextSize(15);
        button.setMinHeight(dp(54));
        button.setMinimumHeight(dp(54));
        button.setPadding(dp(8), 0, dp(8), 0);
        return button;
    }

    private Button button(String title) {
        Button button = new Button(this);
        button.setText(title);
        button.setAllCaps(false);
        return button;
    }

    private TextView text(String value, int sp, boolean bold) {
        TextView view = new TextView(this);
        view.setText(value);
        view.setTextSize(sp);
        if (bold) {
            view.setTypeface(Typeface.DEFAULT, Typeface.BOLD);
        }
        return view;
    }

    private LinearLayout.LayoutParams wrap() {
        return new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.WRAP_CONTENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
    }

    private LinearLayout.LayoutParams buttonCell() {
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(0, dp(56), 1);
        params.leftMargin = dp(3);
        params.rightMargin = dp(3);
        return params;
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.WRAP_CONTENT
        );
    }

    private GradientDrawable rounded(int color, int radius) {
        GradientDrawable drawable = new GradientDrawable();
        drawable.setColor(color);
        drawable.setCornerRadius(radius);
        return drawable;
    }

    private String formatTime(int seconds) {
        int safeSeconds = Math.max(0, seconds);
        return String.format(java.util.Locale.US, "%02d:%02d", safeSeconds / 60, safeSeconds % 60);
    }

    private int defaultTimerX(int width) {
        return Math.max(0, (getResources().getDisplayMetrics().widthPixels - width) / 2);
    }

    private int expandedTimerWidth() {
        return Math.min(dp(420), Math.max(dp(320), getResources().getDisplayMetrics().widthPixels - dp(24)));
    }

    private int clamp(int value, int min, int max) {
        return Math.min(max, Math.max(min, value));
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show();
    }
}
