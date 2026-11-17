package app.fletya.ui;

import android.app.Activity;
import android.content.Context;
import android.content.SharedPreferences;
import android.content.res.ColorStateList;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.view.ContextThemeWrapper;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsetsController;
import android.widget.Button;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Shared Android palette. Preferences are private to each installed FLETYA app. */
public final class Appearance {
    private static final int GOLD = 0xFFE6B958;
    private static final int NAVY = 0xFF102345;
    private static final int GARNET = 0xFF881A42;
    private static final int CREAM = 0xFFFAF7F1;
    private static final String PREFERENCES = "fletya_appearance";
    private static final String DARK = "dark";

    private final Activity activity;
    private final SharedPreferences preferences;
    private final int lightTheme;
    private final int darkTheme;
    private boolean dark;
    private Context context;

    public Appearance(Activity activity, int lightTheme, int darkTheme) {
        this.activity = activity;
        this.lightTheme = lightTheme;
        this.darkTheme = darkTheme;
        preferences = activity.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE);
        dark = preferences.getBoolean(DARK, false);
        refreshContext();
    }

    public int theme() { return dark ? darkTheme : lightTheme; }
    public Context context() { return context; }
    public boolean isDark() { return dark; }
    public int canvas() { return dark ? 0xFF101E36 : CREAM; }
    public int surface() { return dark ? 0xFF1B2F50 : 0xFFFFFDFA; }
    public int text() { return dark ? 0xFFF8F4EB : NAVY; }
    public int accent() { return dark ? GOLD : GARNET; }

    public void setDark(boolean next) {
        if (dark == next) return;
        dark = next;
        preferences.edit().putBoolean(DARK, next).apply();
        refreshContext();
        applyWindow();
    }

    private void refreshContext() {
        context = new ContextThemeWrapper(activity, theme());
    }

    @SuppressWarnings("deprecation")
    public void applyWindow() {
        var window = activity.getWindow();
        // PhoneWindow.getInsetsController() requires its decor to exist.
        // This method also runs before the first setContentView during startup.
        var decor = window.getDecorView();
        window.setBackgroundDrawable(new ColorDrawable(canvas()));
        window.setStatusBarColor(canvas());
        window.setNavigationBarColor(canvas());
        if (Build.VERSION.SDK_INT >= 30) {
            var controller = window.getInsetsController();
            if (controller != null) {
                int lightBars = WindowInsetsController.APPEARANCE_LIGHT_STATUS_BARS
                    | WindowInsetsController.APPEARANCE_LIGHT_NAVIGATION_BARS;
                controller.setSystemBarsAppearance(dark ? 0 : lightBars, lightBars);
            }
        } else {
            int lightBars = View.SYSTEM_UI_FLAG_LIGHT_STATUS_BAR | View.SYSTEM_UI_FLAG_LIGHT_NAVIGATION_BAR;
            int flags = decor.getSystemUiVisibility();
            decor.setSystemUiVisibility(dark ? flags & ~lightBars : flags | lightBars);
        }
    }

    public void styleButton(Button button, boolean primary) {
        int fill = primary ? accent() : surface();
        int foreground = primary ? (dark ? NAVY : 0xFFFFFFFF) : accent();
        int ripple = primary && !dark ? 0x33FFFFFF : dark && !primary ? 0x30FFFFFF : 0x220F1E36;
        button.setAllCaps(false);
        button.setTextColor(foreground);
        button.setTypeface(null, Typeface.BOLD);
        button.setTextSize(15);
        button.setMinHeight(dp(48));
        button.setBackgroundTintList(null);
        button.setBackground(new RippleDrawable(ColorStateList.valueOf(ripple),
            shape(fill, 12, primary ? 0 : outline()), null));
        button.setPadding(dp(12), dp(8), dp(12), dp(8));
    }

    public void styleField(EditText field) {
        field.setTextColor(text());
        field.setHintTextColor(dark ? 0xFFC3CEE0 : 0xFF576478);
        field.setBackground(shape(surface(), 12, outline()));
        field.setPadding(dp(12), dp(10), dp(12), dp(10));
    }

    public GradientDrawable card() {
        return shape(surface(), 16, outline());
    }

    private int outline() { return dark ? 0xFF39516F : 0xFFDDD6CA; }

    private GradientDrawable shape(int fill, int radius, int border) {
        var drawable = new GradientDrawable();
        drawable.setColor(fill);
        drawable.setCornerRadius(dp(radius));
        if (border != 0) drawable.setStroke(dp(1), border);
        return drawable;
    }

    public void addBrand(LinearLayout row) {
        var mark = new TextView(context);
        mark.setText("F");
        mark.setTextSize(31);
        mark.setTypeface(null, Typeface.BOLD_ITALIC);
        mark.setTextColor(dark ? GOLD : 0xFF8A600E);
        mark.setGravity(Gravity.CENTER_VERTICAL);
        mark.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        var markSize = new LinearLayout.LayoutParams(-2, -2);
        markSize.setMarginEnd(dp(8));
        row.addView(mark, markSize);

        var name = new TextView(context);
        name.setText("FLETYA");
        name.setTextSize(26);
        name.setTypeface(null, Typeface.BOLD);
        name.setTextColor(text());
        row.addView(name, new LinearLayout.LayoutParams(0, -2, 1));
    }

    public void addAccent(LinearLayout parent) {
        var rule = new View(context);
        rule.setBackground(shape(GOLD, 2, 0));
        rule.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        var size = new LinearLayout.LayoutParams(dp(42), dp(3));
        size.topMargin = dp(4);
        size.bottomMargin = dp(8);
        parent.addView(rule, size);
    }

    public void addChoices(LinearLayout parent, Runnable render) {
        var choices = new android.widget.RadioGroup(context);
        choices.setOrientation(LinearLayout.VERTICAL);
        var light = new android.widget.RadioButton(context);
        var night = new android.widget.RadioButton(context);
        light.setId(View.generateViewId());
        night.setId(View.generateViewId());
        light.setText("Claro");
        night.setText("Oscuro");
        for (var choice : new android.widget.RadioButton[] {light, night}) {
            choice.setTextColor(text());
            choice.setTextSize(16);
            choice.setMinHeight(dp(48));
            choices.addView(choice, new android.widget.RadioGroup.LayoutParams(-1, -2));
        }
        choices.check(dark ? night.getId() : light.getId());
        choices.setOnCheckedChangeListener((group, id) -> {
            setDark(id == night.getId());
            render.run();
        });
        parent.addView(choices);
    }

    private int dp(int value) {
        return Math.round(value * activity.getResources().getDisplayMetrics().density);
    }
}
