package app.fletya.client;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import app.fletya.ui.Appearance;
import android.graphics.Typeface;
import android.location.*;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import app.fletya.maps.RouteMapActivity;
import java.text.NumberFormat;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.*;

/** Independent client app. Service mutations use the signed-in user's token and existing RLS. */
public final class MainActivity extends Activity {
    private Appearance appearance;
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private ClientApi api;
    private LinearLayout root,quoteArea;
    private TextView message,pushStatusView;
    private Button activateNoticesButton;
    private ScrollView scroll;
    private String screen="login",rendered="",originDraft="",destDraft="",profileName="";
    private int vehicleChoice,helperChoice,serviceChoice,historyPage,noticePage;
    private String pendingNoticeJob="";
    private boolean busy,visible,picking,menuOpen,routeLoading,routeFailed,awaitingLocationPermission,requestingNotices;
    private long revision,draftRevision,routeRevision;
    private JSONObject active;
    private boolean showingPayment;
    private EditText originField,destField;
    private LinearLayout pruebasRouteReview;
    private int pruebasVehicleSelection = 0;
    private ClientApi.Quote quote;
    private ClientApi.TestQuote testQuote;
    private JSONArray activeRoutePoints;
    private static final String[] TEST_SERVICES = {"Mudanza", "Paquetería"};
    private String requestId="",routeKey="";
    private ClientMapView previewMap,trackingMap,pickerMap;
    private TextView routeMessage,trackingStatus;
    private LinearLayout routeContainer;
    private JSONObject currentTrackingFix;
    private LocationListener locationListener;
    private EditText locationTarget;
    private long locationRevision;
    private AlertDialog pickerDialog;
    @Override public void onCreate(Bundle state){
        appearance = new Appearance(this, R.style.AppTheme, R.style.AppThemeDark);
        setTheme(appearance.theme());
        super.onCreate(state);
        appearance.applyWindow();
        pendingNoticeJob=getIntent().getStringExtra("notice_job_id");if(pendingNoticeJob==null)pendingNoticeJob="";api=((ClientApplication)getApplication()).api();
        if(api.signedIn()){screen="home";shell();}else login();
    }
    @Override public void onResume(){super.onResume();visible=true;if(api.signedIn()&&!pendingNoticeJob.isEmpty()){String id=pendingNoticeJob;pendingNoticeJob="";openNotice(id);}else if(api.signedIn()&&"home".equals(screen))refresh();if(locationTarget!=null&&locationListener==null&&!awaitingLocationPermission)startLocation();updateFreshness();main.postDelayed(freshnessTick,1000);main.postDelayed(poll,10_000);}
    @Override public void onPause(){visible=false;main.removeCallbacks(poll);main.removeCallbacks(freshnessTick);if(!awaitingLocationPermission)stopLocation();super.onPause();}
    @Override public void onDestroy(){revision++;routeRevision++;main.removeCallbacksAndMessages(null);stopLocation();disposeMaps();if(pickerDialog!=null)pickerDialog.dismiss();worker.shutdownNow();super.onDestroy();}
    private final Runnable poll=new Runnable(){public void run(){if(!visible)return;if(api.signedIn()&&"home".equals(screen)&&!busy&&!picking&&!menuOpen)refresh();main.postDelayed(this,10_000);}};
    private final Runnable freshnessTick=new Runnable(){public void run(){if(!visible)return;updateFreshness();main.postDelayed(this,1000);}};
    private void updateFreshness(){if(activateNoticesButton!=null)activateNoticesButton.setVisibility(PushManager.permitted(this)?View.GONE:View.VISIBLE);if(pushStatusView!=null)pushStatusView.setText(PushManager.report());if("home".equals(screen)&&active!=null&&ClientRules.assigned(active.optString("status"))&&currentTrackingFix!=null){if(trackingStatus!=null)trackingStatus.setText(ClientRules.freshness(currentTrackingFix));if(trackingMap!=null)trackingMap.updateDriver(currentTrackingFix);}}
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private TextView text(LinearLayout parent,String value,int size,boolean bold){var view=new TextView(appearance.context());view.setText(value);view.setTextSize(size);view.setTextColor(appearance.text());if(bold)view.setTypeface(null,Typeface.BOLD);view.setPadding(0,dp(4),0,dp(8));parent.addView(view);return view;}
    private Button button(LinearLayout parent, String label, Runnable action) {
        return button(parent, label, action, true);
    }
    private Button button(LinearLayout parent, String label, Runnable action, boolean primary) {
        var view = new Button(appearance.context());
        view.setText(label);
        appearance.styleButton(view, primary);
        var layout = new LinearLayout.LayoutParams(-1, -2);
        layout.topMargin = dp(8);
        parent.addView(view, layout);
        view.setOnClickListener(ignored -> { if (!busy) action.run(); });
        return view;
    }
    private LinearLayout card(String title){var box=new LinearLayout(appearance.context());box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(18),dp(18),dp(18),dp(18));box.setBackground(appearance.card());var lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(14);root.addView(box,lp);text(box,title,20,true);return box;}
    private EditText field(LinearLayout box,String label,String value,int type){text(box,label,14,true);var v=new EditText(appearance.context());v.setSingleLine(true);v.setTextSize(16);v.setInputType(type);v.setText(value);v.setMinHeight(dp(48));appearance.styleField(v);box.addView(v,new LinearLayout.LayoutParams(-1,-2));return v;}
    private String money(double value){return NumberFormat.getCurrencyInstance(Locale.forLanguageTag("es-MX")).format(value)+" MXN";}
    private void shell(){
        activateNoticesButton=null;
        int y=scroll!=null&&screen.equals(rendered)?scroll.getScrollY():0;rendered=screen;
        scroll=new ScrollView(appearance.context());scroll.setFillViewport(true);root=new LinearLayout(appearance.context());root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(20),dp(16),dp(20),dp(28));root.setBackgroundColor(appearance.canvas());scroll.addView(root);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{if(Build.VERSION.SDK_INT>=30){var bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.ime());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);}else v.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;});
        setContentView(scroll);scroll.requestApplyInsets();scroll.post(()->{if(scroll!=null)scroll.scrollTo(0,y);});
        var header=new LinearLayout(appearance.context());header.setGravity(Gravity.CENTER_VERTICAL);root.addView(header);
        appearance.addBrand(header);
        if(api.signedIn())button(header,"Menú",()->menu(header),false).setLayoutParams(new LinearLayout.LayoutParams(dp(96),dp(48)));
        text(root,"Cliente · "+BuildConfig.ENVIRONMENT,12,false);appearance.addAccent(root);pushStatusView=api.signedIn()&&BuildConfig.PUSH_ENABLED?text(root,PushManager.report(),13,false):null;message=text(root,"",14,false);message.setTextColor(appearance.accent());
    }
    private interface Work<T>{T run()throws Exception;}
    private interface Done<T>{void run(T value)throws Exception;}
    private <T> void task(Work<T> work,Done<T> done){
        if(busy)return;busy=true;long version=revision;message.setText("Consultando…");
        worker.execute(()->{try{T value=work.run();main.post(()->{if(isDestroyed()||version!=revision)return;busy=false;try{done.run(value);}catch(Exception e){fail(e);}});}catch(Exception e){main.post(()->{if(!isDestroyed()&&version==revision){busy=false;fail(e);}});}});
    }
    private void fail(Exception error){
        if(!api.signedIn()&&!"login".equals(screen)){PushManager.disableLocally(this);login();}
        currentTrackingFix=null;
        if(trackingMap!=null)trackingMap.updateDriver(null);
        if(trackingStatus!=null)trackingStatus.setText("No se pudo actualizar la ubicación. Esperando una nueva recepción.");
        message.setText(error instanceof ClientApi.Failure||error instanceof IllegalArgumentException?error.getMessage():"No se pudo conectar. Actualiza el seguimiento antes de volver a solicitar.");
    }
    private void registrationScreen() {
        screen="register";shell();
        LinearLayout box=card(false?"Crear cuenta de fletero":"Crear cuenta de cliente");
        EditText name=field(box,"Nombre completo","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_WORDS);
        EditText email=field(box,"Correo electrónico","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        EditText password=field(box,"Contraseña (mínimo 8 caracteres)","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);password.setSaveEnabled(false);
        EditText repeat=field(box,"Repite la contraseña","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);repeat.setSaveEnabled(false);
        EditText phone=false?field(box,"Teléfono con lada (10 a 15 dígitos)","",InputType.TYPE_CLASS_PHONE):null;
        Spinner vehicle=new Spinner(appearance.context());
        vehicle.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,new String[]{"Pickup / Estaquita","Camioneta","Camión"}));
        if(false){text(box,"Vehículo",14,true);box.addView(vehicle,new LinearLayout.LayoutParams(-1,dp(52)));}
        EditText plates=false?field(box,"Placas","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_CHARACTERS):null;
        if(false)text(box,"Después de confirmar tu correo, tu cuenta quedará pendiente de revisión por administración. Podrás completar tus datos desde Mi perfil.",14,false);
        button(box,"Crear cuenta",()->{
            String fullName=name.getText().toString(),address=email.getText().toString(),secret=password.getText().toString();
            if(!secret.equals(repeat.getText().toString())){message.setText("Las contraseñas no coinciden.");return;}
            String telephone=phone==null?"":phone.getText().toString(),plate=plates==null?"":plates.getText().toString();String code=new String[]{"pickup","camioneta","camion"}[vehicle.getSelectedItemPosition()];
            task(()->{api.register(fullName,address,secret,telephone,code,plate);return true;},ok->{password.setText("");repeat.setText("");screen="verify";shell();LinearLayout confirmation=card("Confirma tu correo");text(confirmation,"Si el registro procede, recibirás un correo de FLETYA. Abre el enlace de confirmación y vuelve a esta app para iniciar sesión.",16,false);button(confirmation,"Reenviar confirmación",()->task(()->{api.resendConfirmation(address);return true;},sent->message.setText("Si corresponde, enviamos otro correo. Revisa también spam.")));button(root,"Ya confirmé · Iniciar sesión",this::login);});
        });
        button(root,"Volver a iniciar sesión",this::login);
    }
    private void recoveryScreen() {
        screen="recover";shell();LinearLayout box=card("Recuperar contraseña");
        EditText email=field(box,"Correo de tu cuenta","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        text(box,"Te enviaremos un enlace para elegir una contraseña nueva. Después vuelve a la app e inicia sesión.",15,false);
        button(box,"Enviar enlace de recuperación",()->{String address=email.getText().toString();task(()->{api.recover(address);return true;},ok->message.setText("Si existe una cuenta con ese correo, recibirás el enlace. Revisa también spam."));});
        button(root,"Volver a iniciar sesión",this::login);
    }
    private void login(){
        debtScreen=false;resetDraft();disposeMaps();active=null;currentTrackingFix=null;trackingStatus=null;screen="login";shell();
        var box=card("Pide tu flete");text(box,"Entra con tu cuenta de cliente de FLETYA.",16,false);
        var email=field(box,"Correo electrónico","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        var password=field(box,"Contraseña","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);password.setSaveEnabled(false);
        button(box,"Iniciar sesión",()->{String address=email.getText().toString().trim(),secret=password.getText().toString();if(address.isEmpty()||secret.isEmpty()){message.setText("Escribe tu correo y contraseña.");return;}task(()->{api.login(address,secret);return true;},ok->{password.setText("");screen="home";refresh();});});
        button(box,"Crear cuenta de cliente",this::registrationScreen);button(box,"Olvidé mi contraseña",this::recoveryScreen);
    }
    private void menu(View anchor){
        var menu=new PopupMenu(appearance.context(),anchor);menu.getMenu().add(0,1,0,"Solicitar / Seguimiento");menu.getMenu().add(0,2,1,"Historial de servicios");menu.getMenu().add(0,3,2,"Mi perfil");menu.getMenu().add(0,7,5,"Apariencia");menu.getMenu().add(0,4,6,"Cerrar sesión");menu.getMenu().add(0,5,3,"Avisos de mis servicios");if(BuildConfig.PUSH_ENABLED)menu.getMenu().add(0,6,4,"Activar avisos del teléfono");
        menu.setOnMenuItemClickListener(item->{if(busy)return true;stopLocation();switch(item.getItemId()){case 1->{screen="home";refresh();}case 2->{clearTrackingMap();historyPage=0;history();}case 3->{clearTrackingMap();profile();}case 4->logout();case 5->{clearTrackingMap();noticePage=0;notices();}case 6->activateNotices();case 7->showAppearance();default->{return false;}}return true;});menuOpen=true;menu.setOnDismissListener(m->menuOpen=false);menu.show();
    }
    private void showAppearance() {
        clearPreview();
        screen = "appearance";
        shell();
        var box = card("Apariencia");
        appearance.addChoices(box, this::showAppearance);
        button(root, "Volver al seguimiento", () -> {
            screen = "home";
            shell();
            refresh();
        }, false);
    }
    private record Panel(JSONObject profile,JSONArray jobs,ClientApi.Tracking tracking,boolean trackingError,JSONObject payment,JSONArray arrivals,JSONArray debts){}
    private boolean debtScreen=false;
    private void renderDebt(JSONArray debts){
        screen="home";debtScreen=true;stopLocation();clearTrackingMap();clearPreview();originField=null;destField=null;quote=null;testQuote=null;active=null;shell();
        var box=card("Pago pendiente · Cuenta restringida");
        text(box,"Regulariza tu pago antes de solicitar otro flete.",17,true).setTextColor(0xFFDC5353);
        for(int i=0;i<debts.length();i++){JSONObject debt=debts.optJSONObject(i);if(debt==null)continue;
            text(box,String.format(java.util.Locale.US,"$%.2f MXN",debt.optDouble("amount",0)),22,true).setTextColor(0xFFDC5353);
            String due=debt.optString("payment_due_at","");
            if(!debt.isNull("payment_due_at")&&!due.isEmpty())try{due=java.text.DateFormat.getDateTimeInstance().format(java.util.Date.from(java.time.OffsetDateTime.parse(due).toInstant()));}catch(Exception ignored){}
            text(box,debt.isNull("payment_due_at")?"Incidencia pendiente de resolución.":"Fecha límite: "+due,15,false);
        }
        text(box,"Contacta con soporte de FLETYA para regularizar el pago.",15,false);
        var blocked=button(box,"Solicitar flete — bloqueado",()->{});blocked.setEnabled(false);blocked.setBackgroundTintList(android.content.res.ColorStateList.valueOf(0xFF666666));blocked.setTextColor(0xFFFFFFFF);
        button(box,"Actualizar estado",this::refresh);button(root,"Historial de servicios",()->{historyPage=0;history();});
    }
    private void refresh(){
        if(!visible||busy||picking||requestingNotices||!api.signedIn())return;
        task(()->{var profile=api.profile();var debts=api.cashDebts();var jobs=api.activeJobs();var tracking=new ClientApi.Tracking(null,null);boolean error=false;
            if(jobs.length()==1&&ClientRules.assigned(jobs.getJSONObject(0).optString("status")))try{tracking=api.tracking(jobs.getJSONObject(0));}catch(Exception e){if(!api.signedIn())throw e;error=true;}
            JSONObject payment = null;
            if (sandboxPayments() && jobs.length() == 0) {
                try {
                    payment = api.sandboxPayment(null, null, null);
                    if ("booked".equals(payment.optString("state"))) jobs = api.activeJobs();
                } catch (ClientApi.Failure failure) {
                    if (failure.status != 503) throw failure;
                }
            }
            JSONArray arrivals = new JSONArray();
            if (jobs.length()==1 && ClientRules.assigned(jobs.getJSONObject(0).optString("status"))) {
                try { arrivals=api.arrivalNotices(jobs.getJSONObject(0).getString("id")); }
                catch(Exception e) { if(!api.signedIn())throw e; }
            }
            return new Panel(profile,jobs,tracking,error,payment,arrivals,debts);
        },panel->{
            if(!visible||!"home".equals(screen))return;
            PushManager.activate(this,api);
            if (PushManager.shouldRequestOnFirstUse(this)) requestNoticePermission();
            profileName=panel.profile().optString("full_name","cliente");
            if(panel.debts().length()>0){renderDebt(panel.debts());return;}
            if(debtScreen){debtScreen=false;originField=null;}
            if(panel.jobs().length()>1){clearTrackingMap();active=null;shell();text(card("Revisión necesaria"),"Tienes más de un servicio activo. Consulta con administración antes de pedir otro.",16,false);button(root,"Actualizar seguimiento",this::refresh);return;}
            JSONObject next=panel.jobs().length()==1?panel.jobs().getJSONObject(0):null;
            if (next == null && panel.payment() != null && ("pending".equals(panel.payment().optString("state"))
                || "review".equals(panel.payment().optString("state")))) {
                renderPayment(panel.payment());
                return;
            }
            if (showingPayment) {
                showingPayment = false;
                originField = null;
            }
            if(next==null&&active==null&&originField!=null&&originField.isAttachedToWindow()&&"home".equals(rendered)){message.setText("");return;}
            active=next;
            if(active==null){clearTrackingMap();form();}else{stopLocation();clearPreview();quote=null;testQuote=null;requestId="";renderActive(panel.tracking(),panel.trackingError(),panel.arrivals());}
        });
    }
    // Isolated prototype: does not create jobs or change existing payment/quote contracts.
    private void cargoFormPrototype(LinearLayout box){
        text(box,"¿Qué vas a transportar?",17,true);
        text(box,"Describe la carga, revisa el precio y confirma tu solicitud.",13,false);
        text(box,"1. Elige qué transportas",14,true);
        var category=new Spinner(appearance.context());
        category.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,new String[]{"Selecciona categoría","Paquetería / entregas comerciales","Mudanza","Materiales"}));
        box.addView(category);
        var description=field(box,"Describe la carga (obligatorio)","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES|InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        description.setSingleLine(false);description.setMinLines(3);
        var quantity=field(box,"Cantidad aproximada de piezas","",InputType.TYPE_CLASS_NUMBER);
        var dimensions=field(box,"Dimensiones aproximadas (cm)","",InputType.TYPE_CLASS_TEXT);
        var weight=field(box,"Peso aproximado total (kg)","",InputType.TYPE_CLASS_NUMBER|InputType.TYPE_NUMBER_FLAG_DECIMAL);
        text(box,"2. Elige el vehículo",14,true);
        var vehicle=new Spinner(appearance.context());vehicle.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,new String[]{"Selecciona vehículo","Camioneta pickup","Estaquita abierta","Estaquita caja seca","Camión de 3.5 toneladas"}));text(box,"Vehículo",14,true);box.addView(vehicle);
        vehicle.setSelection(pruebasVehicleSelection);
        vehicle.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int position,long id){if(pruebasVehicleSelection!=position){pruebasVehicleSelection=position;invalidateQuote();}}});
        text(box,"3. ¿Necesitas ayuda para cargar?",14,true);
        var helpers=new Spinner(appearance.context());helpers.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,new String[]{"Sin ayudante adicional","1 ayudante","2 ayudantes","3 ayudantes"}));text(box,"Ayudantes adicionales al conductor",14,true);box.addView(helpers);
        text(box,"4. Acceso a la carga (opcional)",14,true);
        var pickupLevel=field(box,"Nivel de recogida (0 = planta baja)","0",InputType.TYPE_CLASS_NUMBER);
        var pickupElevator=new CheckBox(appearance.context());pickupElevator.setText("Elevador apto para la carga en recogida");box.addView(pickupElevator);
        var dropoffLevel=field(box,"Nivel de entrega (0 = planta baja)","0",InputType.TYPE_CLASS_NUMBER);
        var dropoffElevator=new CheckBox(appearance.context());dropoffElevator.setText("Elevador apto para la carga en entrega");box.addView(dropoffElevator);
        var fragile=new CheckBox(appearance.context());fragile.setText("Carga frágil");box.addView(fragile);
        var access=field(box,"Observaciones de acceso y maniobras (opcional)","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        text(box,"Usaremos los puntos de recogida y entrega que elegiste arriba.",13,false);
        var result=text(box,"",14,false);
        LinearLayout routeReview=new LinearLayout(appearance.context());routeReview.setOrientation(LinearLayout.VERTICAL);box.addView(routeReview);
        pruebasRouteReview=routeReview;
        final Runnable[] confirmAction={null};
        final Button[] quoteButton={null};
        quoteButton[0]=button(box,"Ver precio",()->{
            if(confirmAction[0]!=null){confirmAction[0].run();return;}
            if(category.getSelectedItemPosition()==0||vehicle.getSelectedItemPosition()==0||description.getText().toString().trim().length()<3){result.setText("Selecciona categoría y vehículo y describe la carga. Cantidad, medidas y peso son opcionales.");return;}
            confirmAction[0]=null;quoteButton[0].setText("Ver precio");
            try{
                int q=quantity.getText().toString().trim().isEmpty()?0:Integer.parseInt(quantity.getText().toString().trim()),p=Integer.parseInt(pickupLevel.getText().toString()),d=Integer.parseInt(dropoffLevel.getText().toString());double w=weight.getText().toString().trim().isEmpty()?0:Double.parseDouble(weight.getText().toString().trim());
                if(q<0||p<0||d<0||!Double.isFinite(w)||w<0||w>3500){result.setText("Revisa cantidad, niveles y peso. La capacidad real depende del vehículo verificado.");return;}
                result.setText(category.getSelectedItem()+"\nCarga: "+description.getText().toString().trim()+"\nCantidad: "+q+" · "+w+" kg\nDimensiones: "+dimensions.getText()+"\n"+vehicle.getSelectedItem()+" · "+helpers.getSelectedItem()+"\nRecogida: nivel "+p+" · "+(p==0?"Sin suplemento":pickupElevator.isChecked()?"Elevador":"Escaleras")+"\nEntrega: nivel "+d+" · "+(d==0?"Sin suplemento":dropoffElevator.isChecked()?"Elevador":"Escaleras")+"\n"+(fragile.isChecked()?"Carga frágil\n":"")+"Observaciones: "+access.getText()+"\nVista previa: sin pedido ni cobro.");
                final String summary=result.getText().toString();
                final String cat=new String[]{"","Paquetería","Mudanza","Materiales"}[category.getSelectedItemPosition()];
                final String start=originField.getText().toString().trim(),end=destField.getText().toString().trim();
                final int h=helpers.getSelectedItemPosition();
                final boolean pe=pickupElevator.isChecked(),de=dropoffElevator.isChecked();
                if(start.isEmpty()||end.isEmpty()){result.setText("Indica recogida y destino en los campos principales.");return;}
                result.setText("Consultando ruta y tarifas…");
                routeReview.removeAllViews();
                final long routeDraft=draftRevision;
                final String cargoSnapshot=description.getText().toString()+"|"+quantity.getText()+"|"+dimensions.getText()+"|"+weight.getText()+"|"+access.getText();
                final int categorySnapshot=category.getSelectedItemPosition(),vehicleSnapshot=vehicle.getSelectedItemPosition();
                final boolean fragileSnapshot=fragile.isChecked();
                final String vehicleCode=new String[]{"","pickup","estaquita_abierta","estaquita_caja_seca","camion_3_5t"}[vehicleSnapshot];
                task(()->{
                    try{return api.previewVehicleRoute(start,end,vehicleCode,cat,h,p,pe,d,de);}
                    catch(Exception error){
                        return new JSONObject().put("_quote_error",error instanceof ClientApi.Failure || error instanceof IllegalArgumentException
                            ?String.valueOf(error.getMessage()):"No se pudo completar la consulta de ruta. Revisa la conexión e inténtalo otra vez.");
                    }
                },price->{
                    if(price.has("_quote_error")){
                        routeReview.removeAllViews();
                        result.setText("No se pudo cotizar: "+price.optString("_quote_error"));
                        return;
                    }
                    String currentCargo=description.getText().toString()+"|"+quantity.getText()+"|"+dimensions.getText()+"|"+weight.getText()+"|"+access.getText();
                    if(routeDraft!=draftRevision || !start.equals(originField.getText().toString().trim()) || !end.equals(destField.getText().toString().trim()) || !cargoSnapshot.equals(currentCargo) || categorySnapshot!=category.getSelectedItemPosition() || vehicleSnapshot!=vehicle.getSelectedItemPosition() || h!=helpers.getSelectedItemPosition() || !String.valueOf(p).equals(pickupLevel.getText().toString().trim().isEmpty()?"0":pickupLevel.getText().toString().trim()) || !String.valueOf(d).equals(dropoffLevel.getText().toString().trim().isEmpty()?"0":dropoffLevel.getText().toString().trim()) || pe!=pickupElevator.isChecked() || de!=dropoffElevator.isChecked() || fragileSnapshot!=fragile.isChecked()) {routeReview.removeAllViews();result.setText("Cambiaste los datos. Vuelve a cotizar para ver un precio actualizado.");return;}
                    result.setText(price.optBoolean("available")?"Cotización de prueba\n\n"+money(price.getDouble("total"))+"\n"+String.format(java.util.Locale.getDefault(),"%.2f km",price.getDouble("distance_km"))+" · "+vehicle.getSelectedItem()+"\n"+category.getSelectedItem()+" · "+helpers.getSelectedItem()+"\nPago en efectivo al entregar\n\nPrecio sujeto a los datos indicados.":"No hay una tarifa disponible para este vehículo.");
                    if(price.optBoolean("available") && price.has("saved_quote_id")) {
                        final String savedQuote=price.getString("saved_quote_id");
                        final String requestId=UUID.randomUUID().toString();
                        final String quotedDescription=description.getText().toString().trim();
                        final String quotedSummary=summary;
                        confirmAction[0]=()->{
                            String current=description.getText().toString()+"|"+quantity.getText()+"|"+dimensions.getText()+"|"+weight.getText()+"|"+access.getText();
                            if(routeDraft!=draftRevision || !start.equals(originField.getText().toString().trim())
                                || !end.equals(destField.getText().toString().trim()) || !cargoSnapshot.equals(current)
                                || categorySnapshot!=category.getSelectedItemPosition() || vehicleSnapshot!=vehicle.getSelectedItemPosition()
                                || h!=helpers.getSelectedItemPosition() || pe!=pickupElevator.isChecked() || de!=dropoffElevator.isChecked()
                                || fragileSnapshot!=fragile.isChecked() || !String.valueOf(p).equals(pickupLevel.getText().toString().trim().isEmpty()?"0":pickupLevel.getText().toString().trim())
                                || !String.valueOf(d).equals(dropoffLevel.getText().toString().trim().isEmpty()?"0":dropoffLevel.getText().toString().trim())) {
                                routeReview.removeAllViews();confirmAction[0]=null;quoteButton[0].setText("Ver precio");result.setText("Cambiaste los datos. Vuelve a cotizar antes de confirmar.");return;
                            }
                            dialog()
                                .setTitle("Confirmar solicitud de prueba")
                                .setMessage("Se enviará un pedido al sistema de Pruebas. Pago en efectivo. Total: "+money(price.optDouble("total"))+"\n\n"+quotedSummary.replace("Vista previa: sin pedido ni cobro.",""))
                                .setNegativeButton("Volver",null)
                                .setPositiveButton("Solicitar flete",(dialog,which)->{
                                    if(busy){result.setText("Actualizando datos. Espera e intenta confirmar nuevamente.");return;}
                                    result.setText("Enviando solicitud…");
                                    quoteButton[0].setEnabled(false);
                                    task(()->{
                                        try{return api.confirmSavedCargoQuote(savedQuote,requestId,quotedDescription);}
                                        catch(Exception error){
                                            JSONObject failure=new JSONObject();
                                            failure.put("confirmation_error",error instanceof ClientApi.Failure?error.getMessage():"No se pudo verificar el envío. Consulta el seguimiento antes de reintentar.");
                                            return failure;
                                        }
                                    },job->{
                                        quoteButton[0].setEnabled(true);
                                        if(job.has("confirmation_error")){
                                            String error=job.optString("confirmation_error");
                                            result.setText(error);
                                            dialog().setTitle("No se pudo confirmar").setMessage(error).setPositiveButton("Entendido",null).show();
                                            return;
                                        }
                                        routeReview.removeAllViews();
                                        confirmAction[0]=null;quoteButton[0].setText("Ver precio");
                                        result.setText("Solicitud creada en Pruebas. Folio: "+job.optString("id"));
                                        refresh();
                                    });
                                }).show();
                        };
                        quoteButton[0].setText("Confirmar flete");
                    }
                    if(BuildConfig.NATIVE_ROUTE_MAP)button(routeReview,"Ver y confirmar ruta en mapa",()->{
                        try{RouteMapActivity.show(this,RouteMapData.decode(price.getString("route_polyline")));}
                        catch(Exception error){message.setText("No se pudo mostrar la ruta. Revisa las direcciones.");}
                    },false);
                });
            }catch(NumberFormatException ex){result.setText("Revisa los campos numéricos.");}
        });
    }
    private void form(){
        screen="home";shell();text(root,"Hola, "+profileName,17,true);
        var intro=card("Solicitar flete");text(intro,"Elige la ruta y revisa el precio antes de confirmar.",15,false);
        addNoticePermissionButton(intro);
        originField=field(intro,"Punto de recogida",originDraft,InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        if(isPruebas())text(intro,"Puedes escribir un lugar por nombre (por ejemplo, Plaza Las Américas, Cancún) o elegirlo en el mapa. Confirma la ruta antes de continuar.",13,false);
        if (isPruebas()) compactLocationActions(intro, originField);
        else {button(intro,"Elegir recogida en mapa",()->picker(originField),false);button(intro,"Usar mi ubicación como recogida",()->locate(originField),false);}
        destField=field(intro,"Destino",destDraft,InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        if (isPruebas()) compactLocationActions(intro, destField);
        else {button(intro,"Elegir entrega en mapa",()->picker(destField),false);button(intro,"Usar mi ubicación como entrega",()->locate(destField),false);}
        watch(originField,true);watch(destField,false);
        if(isPruebas()) {
            LinearLayout cargoDetails = new LinearLayout(appearance.context());
            cargoDetails.setOrientation(LinearLayout.VERTICAL);
            cargoDetails.setPadding(dp(8),dp(8),dp(8),dp(12));
            cargoFormPrototype(cargoDetails);
            cargoDetails.setVisibility(View.GONE);
            Button toggleCargo = button(intro,"＋ Describir lo que vas a transportar",()->{
                boolean open=cargoDetails.getVisibility()!=View.VISIBLE;
                cargoDetails.setVisibility(open?View.VISIBLE:View.GONE);
            },false);
            intro.addView(cargoDetails);
        }
        if(!isPruebas())spinner(intro,"Vehículo",new String[]{"Pickup / Estaquita","Camioneta","Camión"},vehicleChoice,0);
        if(!isPruebas()) {
        spinner(intro,"Ayudantes",new String[]{"Sin ayudante","1 ayudante","2 ayudantes"},helperChoice,1);
        spinner(intro,"Servicio",availableServices(),serviceChoice,2);
        }
        if(!isPruebas())button(intro,"Cotizar flete",this::calculate);
        if(!isPruebas()){quoteArea=new LinearLayout(appearance.context());quoteArea.setOrientation(LinearLayout.VERTICAL);intro.addView(quoteArea);showQuote();}
        else quoteArea=null;
    }
    private void compactLocationActions(LinearLayout parent, EditText target) {
        LinearLayout actions = new LinearLayout(appearance.context());
        actions.setOrientation(LinearLayout.HORIZONTAL);
        LinearLayout.LayoutParams row = new LinearLayout.LayoutParams(-1, -2);
        row.topMargin = dp(4);
        parent.addView(actions, row);
        Button map = button(actions, "⌖ Mapa", () -> picker(target), false);
        LinearLayout.LayoutParams mapParams = new LinearLayout.LayoutParams(0, dp(46), 1);
        mapParams.setMarginEnd(dp(8));
        map.setLayoutParams(mapParams);
        Button location = button(actions, "◎ Mi ubicación", () -> locate(target), false);
        location.setLayoutParams(new LinearLayout.LayoutParams(0, dp(46), 1));
    }
    private void watch(EditText field,boolean origin){field.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){}public void afterTextChanged(Editable value){String next=value.toString();if(origin){if(next.equals(originDraft))return;originDraft=next;}else{if(next.equals(destDraft))return;destDraft=next;}invalidateQuote();}});}
    private void spinner(LinearLayout box,String label,String[] items,int selected,int kind){
        text(box,label,14,true);var spinner=new Spinner(appearance.context());spinner.setAdapter(new ArrayAdapter<>(appearance.context(),android.R.layout.simple_spinner_dropdown_item,items));spinner.setSelection(selected);box.addView(spinner,new LinearLayout.LayoutParams(-1,dp(52)));
        spinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int position,long id){int old=kind==0?vehicleChoice:kind==1?helperChoice:serviceChoice;if(old==position)return;if(kind==0)vehicleChoice=position;else if(kind==1)helperChoice=position;else serviceChoice=position;invalidateQuote();}});
    }
    private void invalidateQuote(){draftRevision++;quote=null;testQuote=null;requestId="";if(pruebasRouteReview!=null)pruebasRouteReview.removeAllViews();clearPreview();if(quoteArea!=null){quoteArea.removeAllViews();text(quoteArea,"Calcula el precio después de elegir tu ruta.",14,false);}}
    private String[] availableServices() {
        return "PRUEBAS".equals(BuildConfig.ENVIRONMENT) ? TEST_SERVICES : ClientRules.SERVICES;
    }
    private void calculate(){
        if(isPruebas()) {message.setText("Para evitar solicitudes con un vehículo incorrecto, la cotización definitiva está pausada mientras conectamos las cuatro categorías. Usa la vista previa de carga.");return;}
        String from=originDraft,to=destDraft,vehicle=ClientRules.VEHICLES[vehicleChoice],service=availableServices()[serviceChoice];int helpers=helperChoice;long draft=draftRevision;
        task(()->BuildConfig.TEST_ROUTE_PRICING ? api.quoteForTest(from,to,vehicle,helpers,service) : new ClientApi.TestQuote(api.quote(from,to,vehicle,helpers,service), null),value->{if(draft!=draftRevision){message.setText("La ruta cambió. Calcula de nuevo el precio.");return;}testQuote=value;quote=value.quote();requestId=UUID.randomUUID().toString();showQuote();message.setText("Revisa el precio y confirma cuando estés listo.");});
    }
    private void showQuote(){
        if(quoteArea==null)return;quoteArea.removeAllViews();
        if(quote==null){text(quoteArea,"Elige origen y destino para calcular el precio.",14,false);return;}
        text(quoteArea,money(quote.price()),28,true).setTextColor(appearance.accent());text(quoteArea,quote.km()+" km · "+quote.duration(),15,false);
        String pricing = BuildConfig.TEST_ROUTE_PRICING && "pickup".equals(quote.vehicle())
            ? "$400 hasta 3 km · $35 por km adicional"
            : "Base + distancia + vehículo";
        if (quote.helpers() > 0) pricing += " + " + quote.helpers() + " ayudante(s)";
        text(quoteArea, pricing, 13, false);
        clearPreview();
        try{previewMap=new ClientMapView(appearance.context());previewMap.route(quote.polyline());quoteArea.addView(previewMap,new LinearLayout.LayoutParams(-1,dp(240)));}catch(Exception error){clearPreview();text(quoteArea,"Vista de mapa no disponible. Revisa las direcciones antes de solicitar.",13,false);}
        if (BuildConfig.NATIVE_ROUTE_MAP) {
            button(quoteArea, "Ver ruta en mapa", () -> {
                try { RouteMapActivity.show(this, RouteMapData.decode(quote.polyline())); }
                catch (Exception error) { message.setText("No se pudo abrir la ruta."); }
            });
        }
        if (sandboxPayments()) {
            text(quoteArea, "Elige cómo pagar", 15, true);
            if (offersCashPayment()) button(quoteArea, cashPaymentLabel(), this::confirmRequest);
            button(quoteArea, "Autorizar tarjeta de prueba", () -> beginPayment("card"));
            if (isPruebas()) button(quoteArea, "Pagar por SPEI de prueba", () -> beginPayment("spei"));
        } else {
            if (offersCashPayment()) text(quoteArea, cashPaymentLabel(), 15, true);
            button(quoteArea,"Solicitar FLETYA",this::confirmRequest);
        }
    }
    private boolean isPruebas() {
        return "PRUEBAS".equals(BuildConfig.ENVIRONMENT);
    }
    private boolean sandboxPayments() {
        return isPruebas() || (BuildConfig.PILOT_SANDBOX_CARD && "133d9fff-26d4-4f72-aabf-c65c974b7109".equals(api.userId()));
    }

    private void beginPayment(String method) {
        if (testQuote == null) return;
        ClientApi.TestQuote selected = testQuote;
        String id = requestId;
        picking = true;
        dialog().setTitle("Confirmar pago de prueba")
            .setMessage(paymentLabel(method) + " · " + money(selected.quote().price())
                + ("card".equals(method) ? "\nEl importe se reserva. Solo se cobra si un fletero acepta." : ""))
            .setNegativeButton("Volver", null)
            .setPositiveButton("Ir a Stripe", (d, w) -> task(() -> api.sandboxPayment(selected, id, method), payment -> {
                if (!"pending".equals(payment.optString("state"))) {
                    refresh();
                    return;
                }
                resetDraft();
                renderPayment(payment);
                if (!payment.isNull("url")) open(payment.getString("url"));
            })).setOnDismissListener(d -> picking = false).show();
    }

    private void renderPayment(JSONObject payment) {
        active = null;
        showingPayment = true;
        stopLocation();
        clearPreview();
        clearTrackingMap();
        shell();
        boolean review = "review".equals(payment.optString("state"));
        var box = card(review ? "Pago en revisión" : "Pago de prueba pendiente");
        text(box, paymentLabel(payment.optString("method")) + " · " + money(payment.optDouble("amount")), 16, true);
        text(box, review ? "Stripe confirmó el pago. El servicio requiere revisión."
            : "Al volver de Stripe, FLETYA consultará el pago. La solicitud se crea cuando Stripe lo confirme.", 15, false);
        if (!payment.isNull("url")) {
            button(box, "Abrir Stripe", () -> open(payment.optString("url")));
            button(box, "Cancelar pago de prueba", () -> dialog().setTitle("¿Cancelar el pago de prueba?")
                .setNegativeButton("Volver", null)
                .setPositiveButton("Cancelar pago", (d, w) ->
                    task(api::cancelSandboxPayment, result -> refresh())).show());
        }
        button(box, "Consultar pago", this::refresh);
    }

    private String paymentLabel(String method) {
        return "spei".equals(method) ? "Transferencia SPEI" : "Tarjeta";
    }

    private boolean offersCashPayment() {
        return BuildConfig.TEST_ROUTE_PRICING;
    }
    private String cashPaymentLabel() {
        return isPruebas() ? "Pago en efectivo simulado" : "Pago en efectivo al entregar";
    }
    private void confirmRequest(){
        if(quote==null)return;var selected=quote;String id=requestId;long draft=draftRevision;
        picking=true;
        boolean cash = offersCashPayment();
        dialog().setTitle("¿Confirmar el flete?").setMessage(selected.origin()+"\n→ "+selected.destination()+"\n\n"+money(selected.price())+(cash ? "\n" + cashPaymentLabel() + "." : "")+"\nSujeto a disponibilidad de fleteros.")
            .setNegativeButton("Volver",null).setPositiveButton("Confirmar solicitud",(d,w)->{
                if(quote!=selected||draft!=draftRevision)return;
                ClientApi.TestQuote selectedTest = testQuote;
                task(()->cash ? api.createCashRequest(selectedTest,id) : BuildConfig.TEST_ROUTE_PRICING ? api.createForTest(selectedTest,id) : api.create(selected,id),job->{resetDraft();active=job;clearPreview();refresh();});
            }).setOnDismissListener(d->picking=false).show();
    }
    private void details(LinearLayout box,JSONObject job){
        if (sandboxPayments() && !job.isNull("sandbox_payment_method")) {
            String label = switch (job.optString("sandbox_card_state")) {
                case "held" -> "Tarjeta autorizada · Cobro al confirmar fletero";
                case "capturing" -> "Confirmando cobro con Stripe";
                case "released" -> "Reserva de tarjeta liberada";
                default -> "Pago confirmado · " + paymentLabel(job.optString("sandbox_payment_method")) + " de prueba";
            };
            text(box, label, 15, true);
            String refund = switch (job.optString("sandbox_refund_state")) {
                case "requested" -> "Reembolso solicitado · " + money(job.optDouble("price"));
                case "confirmed" -> "Reembolso confirmado · " + money(job.optDouble("price"));
                case "review" -> "Reembolso en revisión";
                case "denied" -> "Reembolso rechazado";
                default -> "";
            };
            if (!refund.isEmpty()) text(box, refund, 15, true);
        }
        if ("cash".equals(job.optString("payment_method"))) {
            text(box, cashPaymentLabel(), 15, true);
            String cashStatus = !job.optString("cash_collected_at", "").isEmpty() && !job.isNull("cash_collected_at")
                ? "Pagado · efectivo recibido por el fletero"
                : "cancelled".equals(job.optString("status")) ? "Pago cancelado" : "Pendiente de confirmación del pago en efectivo";
            text(box, cashStatus, 15, true);
        }
        text(box,"Recogida: "+job.optString("origin"),16,true);text(box,"Entrega: "+job.optString("destination"),16,true);
        text(box,job.optString("service_type")+" · "+ClientRules.vehicle(job.optString("vehicle_type")),15,false);
        text(box,job.optString("distance_km")+" km · Ayudantes: "+job.optInt("helpers"),15,false);text(box,money(job.optDouble("price")),25,true).setTextColor(appearance.accent());
    }
    private void addSandboxRefundButton(LinearLayout box, JSONObject job) {
        if (!sandboxPayments() || !"paid".equals(job.optString("sandbox_card_state"))
            || !job.isNull("sandbox_refund_state")) return;
        String status = job.optString("status");
        boolean review = "picked_up".equals(status) || "completed".equals(status);
        if (!review && !"en_route".equals(status) && !"requested".equals(status)) return;
        String label = review ? "Solicitar revisión de reembolso" : "Cancelar y solicitar reembolso";
        button(box, label, () -> dialog().setTitle(label)
            .setMessage(review ? "Administración revisará el caso. El servicio conserva su estado."
                : "Se cancelará la solicitud y se pedirá la devolución de " + money(job.optDouble("price")) + ".")
            .setNegativeButton("Volver", null)
            .setPositiveButton(review ? "Solicitar revisión" : "Confirmar cancelación", (d, w) ->
                task(() -> api.requestSandboxCardRefund(job.getString("id")), result -> {
                    if ("cancelled".equals(result.optString("status"))) {
                        active = null;
                        clearTrackingMap();
                    }
                    historyPage = 0;
                    history();
                })).show());
    }

    private void renderActive(ClientApi.Tracking tracking,boolean trackingError,JSONArray arrivals){
        screen="home";shell();trackingStatus=null;originField=null;destField=null;quoteArea=null;
        JSONObject job=active;var box=card("Tu servicio");addNoticePermissionButton(box);
        String status=job.optString("status");
        String heading="accepted".equals(status) ? "Confirmando aceptación" : ClientRules.status(status);
        if (ClientRules.assigned(status) && arrivals!=null && arrivals.length()>0) {
            JSONObject latest=arrivals.optJSONObject(0);
            if (latest!=null) {
                String type=latest.optString("type");
                if ("client_arrived_delivery".equals(type) && "picked_up".equals(status))
                    heading="Tu fletero llegó al punto de entrega.";
                else if ("client_arrived_pickup".equals(type) && "en_route".equals(status))
                    heading="Tu fletero llegó al punto de recogida.";
            }
        }
        text(box,heading,19,true);
        details(box,job);
        if("requested".equals(job.optString("status"))&&!job.optString("release_reason","").isEmpty()&&!job.isNull("release_reason"))text(box,"El fletero liberó el servicio. Buscando otro. Motivo: "+job.optString("release_reason"),14,false);
        addSandboxRefundButton(box, job);
        if("requested".equals(job.optString("status"))&&job.isNull("driver_id")
            && !(sandboxPayments() && "paid".equals(job.optString("sandbox_card_state"))))button(box,"Cancelar solicitud",()->dialog().setTitle("¿Cancelar la solicitud?").setMessage("Solo puedes cancelar antes de que un fletero acepte. Quedará en tu historial.").setNegativeButton("Volver",null).setPositiveButton("Cancelar solicitud",(d,w)->task(()->api.cancel(job.optString("id")),result->{active=null;clearTrackingMap();refresh();})).show());
        if(ClientRules.assigned(job.optString("status"))){
            var driverBox=card("Tu fletero asignado");var driver=tracking.driver();var fix=tracking.fix();
            if(driver!=null){text(driverBox,driver.optString("full_name","Sin nombre"),18,true);text(driverBox,"Vehículo: "+ClientRules.vehicle(driver.optString("vehicle_type")),15,false);text(driverBox,"Placas: "+driver.optString("plates","Sin registrar"),16,true);}else text(driverBox,trackingError?"No se pudo actualizar la identificación del fletero.":"Consultando la identificación del fletero…",15,false);
            if(fix!=null){trackingStatus=text(driverBox,ClientRules.freshness(fix),16,true);text(driverBox,"Precisión: "+Math.round(fix.optDouble("accuracy",0))+" m",14,false);text(driverBox,"Última recepción: "+ClientNotices.time(fix.optString("updated_at")),12,false);}else trackingStatus=text(driverBox,trackingError?"No se pudo actualizar la ubicación. Reintenta el seguimiento.":"Esperando ubicación del fletero…",15,false);
        }
        var mapBox=card("Ruta del servicio");routeContainer=mapBox;routeMessage=text(mapBox,"",14,false);currentTrackingFix=trackingError?null:tracking.fix();
        String key=api.userId()+"|"+job.optString("id")+"|"+job.optString("origin")+"|"+job.optString("destination");
        if(!key.equals(routeKey)){clearTrackingMap();routeKey=key;}
        if(trackingMap!=null){attachMap(mapBox);trackingMap.updateDriver(trackingError?null:tracking.fix());routeMessage.setText("Recogida → Entrega · El punto azul indica al fletero; naranja, ubicación desactualizada.");}
        else if(!routeLoading&&!routeFailed)loadTrackingRoute(job,key);
        else routeMessage.setText(routeFailed?"No se pudo cargar la ruta. Pulsa Recargar mapa.":"Cargando ruta…");
        if(trackingMap!=null&&tracking.fix()!=null)button(mapBox,"Ver fletero en mapa",()->trackingMap.centerDriver());
        if (BuildConfig.NATIVE_ROUTE_MAP && activeRoutePoints != null) {
            button(mapBox, "Ver ruta en mapa", () -> RouteMapActivity.show(this, activeRoutePoints));
        }
        button(mapBox,"Recargar mapa",()->{clearTrackingMap();refresh();});button(root,"Actualizar seguimiento",this::refresh);message.setText("");
    }
    private void attachMap(LinearLayout box){if(trackingMap.getParent() instanceof ViewGroup parent)parent.removeView(trackingMap);box.addView(trackingMap,new LinearLayout.LayoutParams(-1,dp(280)));}
    private void loadTrackingRoute(JSONObject job,String key){
        routeLoading=true;
        long session=revision,request=++routeRevision;String user=api.userId();routeMessage.setText("Cargando ruta…");
        worker.execute(()->{try{
            boolean bound = !job.isNull("route_quote_id");
            JSONArray points = bound ? RouteMapData.fromLongitudeFirst(api.savedRoute(job.getString("id")))
                : RouteMapData.decode(api.route(job.optString("origin"),job.optString("destination")).getString("polyline"));
            main.post(()->{
            if(isDestroyed()||session!=revision||request!=routeRevision||!user.equals(api.userId())||!"home".equals(screen)||active==null||!key.equals(routeKey))return;
            try{activeRoutePoints=points;trackingMap=new ClientMapView(appearance.context());trackingMap.route(points);trackingMap.updateDriver(currentTrackingFix);attachMap(routeContainer);routeLoading=false;routeMessage.setText(job.optString("distance_km")+" km · Recogida a entrega");if(currentTrackingFix!=null)button(routeContainer,"Ver fletero en mapa",()->{if(trackingMap!=null)trackingMap.centerDriver();});message.setText("Mapa cargado.");}
            catch(Exception error){clearTrackingMap();routeKey=key;routeFailed=true;routeMessage.setText("No se pudo abrir el mapa. Pulsa Recargar mapa.");}
        });}catch(Exception error){main.post(()->{if(!isDestroyed()&&session==revision&&request==routeRevision&&key.equals(routeKey)&&"home".equals(screen)){routeLoading=false;routeFailed=true;routeMessage.setText("No se pudo cargar la ruta. Pulsa Recargar mapa.");}});}});
    }
    private void clearPreview(){if(previewMap!=null){if(previewMap.getParent() instanceof ViewGroup parent)parent.removeView(previewMap);previewMap.dispose();previewMap=null;}}
    private void clearTrackingMap(){activeRoutePoints=null;routeRevision++;routeKey="";routeLoading=false;routeFailed=false;if(trackingMap!=null){if(trackingMap.getParent() instanceof ViewGroup parent)parent.removeView(trackingMap);trackingMap.dispose();trackingMap=null;}}
    private void disposeMaps(){clearPreview();clearTrackingMap();if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}}
    private void resetDraft(){originDraft="";destDraft="";vehicleChoice=0;helperChoice=0;serviceChoice=0;quote=null;testQuote=null;requestId="";draftRevision++;originField=null;destField=null;quoteArea=null;}
    private void addNoticePermissionButton(LinearLayout parent) {
        if (!BuildConfig.PUSH_ENABLED) return;
        activateNoticesButton = button(parent, "Activar avisos de mi servicio", this::activateNotices);
        activateNoticesButton.setVisibility(PushManager.permitted(this) ? View.GONE : View.VISIBLE);
    }
    private void activateNotices(){
        if (PushManager.shouldRequestOnFirstUse(this)
            || (Build.VERSION.SDK_INT >= 33 && shouldShowRequestPermissionRationale(Manifest.permission.POST_NOTIFICATIONS))) {
            requestNoticePermission();
        }
        else if(!PushManager.permitted(this)){try{startActivity(new Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS,Uri.parse("package:"+getPackageName())));}catch(ActivityNotFoundException error){message.setText("Revisa los permisos de notificaciones en Ajustes.");}}
        else{PushManager.tokenChanged(this,api);message.setText(PushManager.report());}
    }
    private void requestNoticePermission() {
        requestingNotices=true;
        PushManager.markPermissionRequested(this);
        requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 18);
    }
    private void notices(){int page=noticePage;task(()->api.notifications(page*12),rows->{
        screen="notices";shell();card("Avisos de mis servicios");
        if(rows.length()==0)text(root,"No tienes avisos en esta página.",16,false);
        for(int i=0;i<Math.min(12,rows.length());i++){JSONObject notice=rows.getJSONObject(i);LinearLayout box=card((notice.optBoolean("read")?"":"Nuevo · ")+notice.optString("title"));text(box,notice.optString("message"),15,false);text(box,ClientNotices.time(notice.optString("created_at")),13,false);
            if(!notice.isNull("job_id"))button(box,"Ver servicio",()->openNotice(notice.optString("job_id")));
            if(!notice.optBoolean("read"))button(box,"Marcar como leído",()->task(()->{api.markNoticeRead(notice.optString("id"));return true;},ok->notices()));
        }
        if(page>0)button(root,"Anterior",()->{noticePage--;notices();});if(rows.length()>12)button(root,"Ver más",()->{noticePage++;notices();});button(root,"Volver al seguimiento",()->{screen="home";refresh();});message.setText("");
    });}
    private void openNotice(String id){
        try{UUID.fromString(id);}catch(RuntimeException invalid){message.setText("No se pudo abrir el servicio.");return;}
        task(()->{api.profile();return api.job(id);},job->{
            if(job==null){message.setText("El servicio no está disponible para esta cuenta.");return;}
            if(ClientRules.active(job.optString("status"))){screen="home";refresh();return;}
            clearTrackingMap();screen="notice";shell();LinearLayout box=card(ClientRules.status(job.optString("status")));details(box,job);button(root,"Historial de servicios",()->{historyPage=0;history();});button(root,"Volver a solicitar",()->{screen="home";refresh();});message.setText("");
        });
    }
    private void history(){task(()->api.history(historyPage*5),rows->{screen="history";shell();card("Historial de servicios");for(int i=0;i<Math.min(5,rows.length());i++){var job=rows.getJSONObject(i);var box=card(ClientRules.status(job.optString("status")));details(box,job);addSandboxRefundButton(box,job);text(box,job.optString("created_at").split("T")[0],13,false);}if(rows.length()==0)text(root,"No hay servicios en esta página.",16,false);if(historyPage>0)button(root,"Anterior",()->{historyPage--;history();});if(rows.length()>5)button(root,"Ver más",()->{historyPage++;history();});if(sandboxPayments())button(root,"Actualizar historial",this::history);button(root,"Volver al seguimiento",()->{screen="home";refresh();});message.setText("");});}
    private void profile(){task(api::profile,p->{screen="profile";shell();var box=card("Mi perfil de cliente");var name=field(box,"Nombre completo",p.optString("full_name"),InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_WORDS);button(box,"Guardar perfil",()->task(()->{api.saveName(name.getText().toString());return true;},ok->message.setText("Perfil guardado.")));button(root,"Volver al seguimiento",()->{screen="home";refresh();});message.setText("");});}
    private AlertDialog.Builder dialog(){picking=true;return new AlertDialog.Builder(appearance.context()).setOnDismissListener(d->picking=false);}
    private void logout(){dialog().setTitle("¿Cerrar sesión de cliente?").setMessage("Tu servicio seguirá guardado. La app del fletero conserva su propia sesión.").setNegativeButton("Volver",null).setPositiveButton("Cerrar sesión",(d,w)->{stopLocation();disposeMaps();String[] device=PushManager.disableLocally(this);task(()->{try{api.unregisterPush(device[0],device[1]);}catch(Exception ignored){}api.logout();return true;},ok->{revision++;login();});}).show();}
    private void open(String uri){try{startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(uri)));}catch(ActivityNotFoundException error){message.setText("No se pudo abrir el enlace.");}}
    private void picker(EditText target){
        picking=true;var box=new LinearLayout(appearance.context());box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(12),dp(8),dp(12),dp(8));text(box,"Mueve el mapa hasta colocar el centro sobre el punto exacto. También puedes tocar un lugar.",15,false);
        try{pickerMap=new ClientMapView(appearance.context());pickerMap.picker(ClientRules.coordinates(target.getText().toString()));box.addView(pickerMap,new LinearLayout.LayoutParams(-1,dp(340)));
            long draft=draftRevision;pickerDialog=new AlertDialog.Builder(appearance.context()).setTitle(target==originField?"Punto de recogida":"Punto de entrega").setView(box).setNegativeButton("Volver",null).setPositiveButton("Elegir este punto",null).create();
            pickerDialog.setOnShowListener(d->pickerDialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->pickerMap.selected((lat,lng)->{if(draft==draftRevision&&"home".equals(screen)&&active==null)target.setText(String.format(Locale.US,"%.6f, %.6f",lat,lng));pickerDialog.dismiss();},()->Toast.makeText(this,"El mapa sigue cargando. Intenta de nuevo.",Toast.LENGTH_SHORT).show())));
            pickerDialog.setOnDismissListener(d->{picking=false;if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}pickerDialog=null;});pickerDialog.show();
        }catch(Exception error){picking=false;if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}message.setText("No se pudo abrir el mapa. Puedes escribir una dirección.");}
    }
    private void locate(EditText target){
        stopLocation();locationTarget=target;locationRevision=draftRevision;
        if(checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)!=PackageManager.PERMISSION_GRANTED&&checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED){awaitingLocationPermission=true;requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,Manifest.permission.ACCESS_COARSE_LOCATION},10);return;}
        startLocation();
    }
    @Override public void onRequestPermissionsResult(int code,String[] permissions,int[] results){super.onRequestPermissionsResult(code,permissions,results);if(code==18){requestingNotices=false;PushManager.activate(this,api);updateFreshness();if(!PushManager.permitted(this))message.setText(PushManager.report());return;}if(code==10){awaitingLocationPermission=false;if(checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)==PackageManager.PERMISSION_GRANTED||checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED)startLocation();else {stopLocation();message.setText("Puedes elegir el punto en el mapa o escribir la dirección.");}}}
    @SuppressWarnings("deprecation")
    @android.annotation.SuppressLint("MissingPermission")
    private void startLocation(){
        if(!visible||locationTarget==null||active!=null||!"home".equals(screen))return;
        var manager=(LocationManager)getSystemService(LOCATION_SERVICE);message.setText("Buscando tu ubicación…");
        locationListener=new LocationListener(){public void onLocationChanged(Location fix){if((SystemClock.elapsedRealtimeNanos()-fix.getElapsedRealtimeNanos())<0||(SystemClock.elapsedRealtimeNanos()-fix.getElapsedRealtimeNanos())>30_000_000_000L||!ClientRules.validPoint(fix.getLatitude(),fix.getLongitude()))return;var target=locationTarget;long draft=locationRevision;stopLocation();if(visible&&"home".equals(screen)&&active==null&&draft==draftRevision&&target!=null&&(target==originField||target==destField)){target.setText(String.format(Locale.US,"%.6f, %.6f",fix.getLatitude(),fix.getLongitude()));message.setText("Ubicación elegida · precisión "+Math.round(fix.getAccuracy())+" m. Revisa el punto antes de solicitar.");}}public void onProviderEnabled(String p){}public void onProviderDisabled(String p){}public void onStatusChanged(String p,int status,Bundle extras){}};
        boolean requested=false;
        for(String provider:new String[]{LocationManager.GPS_PROVIDER,LocationManager.NETWORK_PROVIDER})try{if(manager.isProviderEnabled(provider)){manager.requestLocationUpdates(provider,1000,0,locationListener,Looper.getMainLooper());requested=true;}}catch(SecurityException|IllegalArgumentException ignored){ /* Approximate permission may allow only network. */ }
        if(!requested){stopLocation();message.setText("Activa la ubicación del móvil o elige el punto en el mapa.");return;}
        main.postDelayed(locationTimeout,20_000);
    }
    private final Runnable locationTimeout=()->{if(locationListener!=null){stopLocation();if(message!=null)message.setText("No se obtuvo una ubicación reciente. Intenta al aire libre o elige el punto en el mapa.");}};
    private void stopLocation(){main.removeCallbacks(locationTimeout);if(locationListener!=null){((LocationManager)getSystemService(LOCATION_SERVICE)).removeUpdates(locationListener);locationListener=null;}locationTarget=null;}
}
