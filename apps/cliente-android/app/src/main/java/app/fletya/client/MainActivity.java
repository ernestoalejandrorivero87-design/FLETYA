package app.fletya.client;

import android.Manifest;
import android.app.*;
import android.content.*;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.*;
import android.net.Uri;
import android.os.*;
import android.text.*;
import android.view.*;
import android.widget.*;
import org.json.*;
import java.text.NumberFormat;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.*;

/** Independent client app. Service mutations use the signed-in user's token and existing RLS. */
public final class MainActivity extends Activity {
    private static final int TEAL=Color.rgb(8,127,136);
    private final Handler main=new Handler(Looper.getMainLooper());
    private final ExecutorService worker=Executors.newSingleThreadExecutor();
    private ClientApi api;
    private LinearLayout root,quoteArea;
    private TextView message;
    private ScrollView scroll;
    private String screen="login",rendered="",originDraft="",destDraft="",profileName="";
    private int vehicleChoice,helperChoice,serviceChoice,historyPage;
    private boolean busy,visible,picking,routeLoading,routeFailed,awaitingLocationPermission;
    private long revision,draftRevision,routeRevision;
    private JSONObject active;
    private EditText originField,destField;
    private ClientApi.Quote quote;
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
        super.onCreate(state);api=((ClientApplication)getApplication()).api();
        if(api.signedIn()){screen="home";shell();}else login();
    }
    @Override public void onResume(){super.onResume();visible=true;if(api.signedIn()&&"home".equals(screen))refresh();if(locationTarget!=null&&locationListener==null&&!awaitingLocationPermission)startLocation();updateFreshness();main.postDelayed(freshnessTick,1000);main.postDelayed(poll,10_000);}
    @Override public void onPause(){visible=false;main.removeCallbacks(poll);main.removeCallbacks(freshnessTick);if(!awaitingLocationPermission)stopLocation();super.onPause();}
    @Override public void onDestroy(){revision++;routeRevision++;main.removeCallbacksAndMessages(null);stopLocation();disposeMaps();if(pickerDialog!=null)pickerDialog.dismiss();worker.shutdownNow();super.onDestroy();}
    private final Runnable poll=new Runnable(){public void run(){if(!visible)return;if(api.signedIn()&&"home".equals(screen)&&!busy&&!picking)refresh();main.postDelayed(this,10_000);}};
    private final Runnable freshnessTick=new Runnable(){public void run(){if(!visible)return;updateFreshness();main.postDelayed(this,1000);}};
    private void updateFreshness(){if("home".equals(screen)&&active!=null&&ClientRules.assigned(active.optString("status"))&&currentTrackingFix!=null){if(trackingStatus!=null)trackingStatus.setText(ClientRules.freshness(currentTrackingFix));if(trackingMap!=null)trackingMap.updateDriver(currentTrackingFix);}}
    private int dp(int n){return Math.round(n*getResources().getDisplayMetrics().density);}
    private GradientDrawable background(int color,int radius){var value=new GradientDrawable();value.setColor(color);value.setCornerRadius(dp(radius));return value;}
    private TextView text(LinearLayout parent,String value,int size,boolean bold){var view=new TextView(this);view.setText(value);view.setTextSize(size);view.setTextColor(Color.rgb(32,45,49));if(bold)view.setTypeface(null,Typeface.BOLD);view.setPadding(0,dp(4),0,dp(8));parent.addView(view);return view;}
    private Button button(LinearLayout parent,String label,Runnable action){var view=new Button(this);view.setText(label);view.setAllCaps(false);view.setTextSize(15);view.setTextColor(Color.WHITE);view.setMinHeight(dp(48));view.setBackground(background(TEAL,10));var lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(8);parent.addView(view,lp);view.setOnClickListener(v->{if(!busy)action.run();});return view;}
    private LinearLayout card(String title){var box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(18),dp(18),dp(18),dp(18));box.setBackground(background(Color.WHITE,16));var lp=new LinearLayout.LayoutParams(-1,-2);lp.topMargin=dp(14);root.addView(box,lp);text(box,title,20,true);return box;}
    private EditText field(LinearLayout box,String label,String value,int type){text(box,label,14,true);var v=new EditText(this);v.setSingleLine(true);v.setTextSize(16);v.setInputType(type);v.setText(value);v.setMinHeight(dp(48));box.addView(v,new LinearLayout.LayoutParams(-1,-2));return v;}
    private String money(double value){return NumberFormat.getCurrencyInstance(Locale.forLanguageTag("es-MX")).format(value)+" MXN";}
    private void shell(){
        int y=scroll!=null&&screen.equals(rendered)?scroll.getScrollY():0;rendered=screen;
        scroll=new ScrollView(this);scroll.setFillViewport(true);root=new LinearLayout(this);root.setOrientation(LinearLayout.VERTICAL);root.setPadding(dp(20),dp(16),dp(20),dp(28));root.setBackgroundColor(Color.rgb(244,247,248));scroll.addView(root);
        scroll.setOnApplyWindowInsetsListener((v,insets)->{if(Build.VERSION.SDK_INT>=30){var bars=insets.getInsets(WindowInsets.Type.systemBars()|WindowInsets.Type.ime());v.setPadding(bars.left,bars.top,bars.right,bars.bottom);}else v.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());return insets;});
        setContentView(scroll);scroll.requestApplyInsets();scroll.post(()->{if(scroll!=null)scroll.scrollTo(0,y);});
        var header=new LinearLayout(this);header.setGravity(Gravity.CENTER_VERTICAL);root.addView(header);
        var title=text(header,"FLETYA",26,true);title.setTextColor(TEAL);title.setLayoutParams(new LinearLayout.LayoutParams(0,-2,1));
        if(api.signedIn())button(header,"Menú",()->menu(header)).setLayoutParams(new LinearLayout.LayoutParams(dp(96),dp(48)));
        text(root,"Clientes · "+BuildConfig.ENVIRONMENT,12,false);message=text(root,"",14,false);message.setTextColor(TEAL);
    }
    private interface Work<T>{T run()throws Exception;}
    private interface Done<T>{void run(T value)throws Exception;}
    private <T> void task(Work<T> work,Done<T> done){
        if(busy)return;busy=true;long version=revision;message.setText("Consultando…");
        worker.execute(()->{try{T value=work.run();main.post(()->{if(isDestroyed()||version!=revision)return;busy=false;try{done.run(value);}catch(Exception e){fail(e);}});}catch(Exception e){main.post(()->{if(!isDestroyed()&&version==revision){busy=false;fail(e);}});}});
    }
    private void fail(Exception error){
        if(!api.signedIn()&&!"login".equals(screen))login();
        currentTrackingFix=null;
        if(trackingMap!=null)trackingMap.updateDriver(null);
        if(trackingStatus!=null)trackingStatus.setText("No se pudo actualizar la ubicación. Esperando una nueva recepción.");
        message.setText(error instanceof ClientApi.Failure||error instanceof IllegalArgumentException?error.getMessage():"No se pudo conectar. Actualiza el seguimiento antes de volver a solicitar.");
    }
    private void login(){
        resetDraft();disposeMaps();active=null;currentTrackingFix=null;trackingStatus=null;screen="login";shell();
        var box=card("Pide tu flete");text(box,"Entra con tu cuenta de cliente de FLETYA.",16,false);
        var email=field(box,"Correo electrónico","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_EMAIL_ADDRESS);
        var password=field(box,"Contraseña","",InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_VARIATION_PASSWORD);password.setSaveEnabled(false);
        button(box,"Iniciar sesión",()->{String address=email.getText().toString().trim(),secret=password.getText().toString();if(address.isEmpty()||secret.isEmpty()){message.setText("Escribe tu correo y contraseña.");return;}task(()->{api.login(address,secret);return true;},ok->{password.setText("");screen="home";refresh();});});
        text(box,"En este piloto, crea tu cuenta o recupera tu contraseña desde la web.",13,false);button(box,"Registro y recuperación en la web",()->open("https://fletya.vercel.app"));
    }
    private void menu(View anchor){
        var menu=new PopupMenu(this,anchor);menu.getMenu().add(0,1,0,"Solicitar / Seguimiento");menu.getMenu().add(0,2,1,"Historial de servicios");menu.getMenu().add(0,3,2,"Mi perfil");menu.getMenu().add(0,4,3,"Cerrar sesión");
        menu.setOnMenuItemClickListener(item->{if(busy)return true;stopLocation();switch(item.getItemId()){case 1->{screen="home";refresh();}case 2->{clearTrackingMap();historyPage=0;history();}case 3->{clearTrackingMap();profile();}case 4->logout();default->{return false;}}return true;});picking=true;menu.setOnDismissListener(m->picking=false);menu.show();
    }
    private record Panel(JSONObject profile,JSONArray jobs,ClientApi.Tracking tracking,boolean trackingError){}
    private void refresh(){
        if(!visible||busy||picking||!api.signedIn())return;
        task(()->{var profile=api.profile();var jobs=api.activeJobs();var tracking=new ClientApi.Tracking(null,null);boolean error=false;
            if(jobs.length()==1&&ClientRules.assigned(jobs.getJSONObject(0).optString("status")))try{tracking=api.tracking(jobs.getJSONObject(0));}catch(Exception e){if(!api.signedIn())throw e;error=true;}
            return new Panel(profile,jobs,tracking,error);
        },panel->{
            if(!visible||!"home".equals(screen))return;
            profileName=panel.profile().optString("full_name","cliente");
            if(panel.jobs().length()>1){clearTrackingMap();active=null;shell();text(card("Revisión necesaria"),"Tienes más de un servicio activo. Consulta con administración antes de pedir otro.",16,false);button(root,"Actualizar seguimiento",this::refresh);return;}
            JSONObject next=panel.jobs().length()==1?panel.jobs().getJSONObject(0):null;
            if(next==null&&active==null&&originField!=null&&originField.getParent()!=null&&"home".equals(rendered)){message.setText("");return;}
            active=next;
            if(active==null){clearTrackingMap();form();}else{stopLocation();clearPreview();quote=null;requestId="";renderActive(panel.tracking(),panel.trackingError());}
        });
    }
    private void form(){
        screen="home";shell();text(root,"Hola, "+profileName,17,true);
        var intro=card("Solicita tu flete");text(intro,"Elige la ruta y revisa el precio antes de confirmar.",15,false);
        originField=field(intro,"Recogida",originDraft,InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        button(intro,"Elegir recogida en mapa",()->picker(originField));button(intro,"Usar mi ubicación como recogida",()->locate(originField));
        destField=field(intro,"Entrega",destDraft,InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_SENTENCES);
        button(intro,"Elegir entrega en mapa",()->picker(destField));button(intro,"Usar mi ubicación como entrega",()->locate(destField));
        watch(originField,true);watch(destField,false);
        spinner(intro,"Vehículo",new String[]{"Pickup / Estaquita","Camioneta","Camión"},vehicleChoice,0);
        spinner(intro,"Ayudantes",new String[]{"Sin ayudante","1 ayudante","2 ayudantes"},helperChoice,1);
        spinner(intro,"Servicio",ClientRules.SERVICES,serviceChoice,2);
        button(intro,"Ver precio y ruta",this::calculate);
        quoteArea=new LinearLayout(this);quoteArea.setOrientation(LinearLayout.VERTICAL);intro.addView(quoteArea);showQuote();
    }
    private void watch(EditText field,boolean origin){field.addTextChangedListener(new TextWatcher(){public void beforeTextChanged(CharSequence s,int start,int count,int after){}public void onTextChanged(CharSequence s,int start,int before,int count){}public void afterTextChanged(Editable value){String next=value.toString();if(origin){if(next.equals(originDraft))return;originDraft=next;}else{if(next.equals(destDraft))return;destDraft=next;}invalidateQuote();}});}
    private void spinner(LinearLayout box,String label,String[] items,int selected,int kind){
        text(box,label,14,true);var spinner=new Spinner(this);spinner.setAdapter(new ArrayAdapter<>(this,android.R.layout.simple_spinner_dropdown_item,items));spinner.setSelection(selected);box.addView(spinner,new LinearLayout.LayoutParams(-1,dp(52)));
        spinner.setOnItemSelectedListener(new AdapterView.OnItemSelectedListener(){public void onNothingSelected(AdapterView<?> p){}public void onItemSelected(AdapterView<?> p,View v,int position,long id){int old=kind==0?vehicleChoice:kind==1?helperChoice:serviceChoice;if(old==position)return;if(kind==0)vehicleChoice=position;else if(kind==1)helperChoice=position;else serviceChoice=position;invalidateQuote();}});
    }
    private void invalidateQuote(){draftRevision++;quote=null;requestId="";clearPreview();if(quoteArea!=null){quoteArea.removeAllViews();text(quoteArea,"Calcula el precio después de elegir tu ruta.",14,false);}}
    private void calculate(){
        String from=originDraft,to=destDraft,vehicle=ClientRules.VEHICLES[vehicleChoice],service=ClientRules.SERVICES[serviceChoice];int helpers=helperChoice;long draft=draftRevision;
        task(()->api.quote(from,to,vehicle,helpers,service),value->{if(draft!=draftRevision){message.setText("La ruta cambió. Calcula de nuevo el precio.");return;}quote=value;requestId=UUID.randomUUID().toString();showQuote();message.setText("Revisa el precio y confirma cuando estés listo.");});
    }
    private void showQuote(){
        if(quoteArea==null)return;quoteArea.removeAllViews();
        if(quote==null){text(quoteArea,"Elige origen y destino para calcular el precio.",14,false);return;}
        text(quoteArea,money(quote.price()),28,true).setTextColor(TEAL);text(quoteArea,quote.km()+" km · "+quote.duration(),15,false);
        text(quoteArea,"Base + distancia + vehículo + "+quote.helpers()+" ayudante(s)",13,false);
        clearPreview();
        try{previewMap=new ClientMapView(this);previewMap.route(quote.polyline());quoteArea.addView(previewMap,new LinearLayout.LayoutParams(-1,dp(240)));}catch(Exception error){clearPreview();text(quoteArea,"Vista de mapa no disponible. Revisa las direcciones antes de solicitar.",13,false);}
        button(quoteArea,"Solicitar FLETYA",this::confirmRequest);
    }
    private void confirmRequest(){
        if(quote==null)return;var selected=quote;String id=requestId;long draft=draftRevision;
        picking=true;
        dialog().setTitle("¿Confirmar el flete?").setMessage(selected.origin()+"\n→ "+selected.destination()+"\n\n"+money(selected.price())+"\nSujeto a disponibilidad de fleteros.")
            .setNegativeButton("Volver",null).setPositiveButton("Confirmar solicitud",(d,w)->{
                if(quote!=selected||draft!=draftRevision)return;
                task(()->api.create(selected,id),job->{resetDraft();active=job;clearPreview();refresh();});
            }).setOnDismissListener(d->picking=false).show();
    }
    private void details(LinearLayout box,JSONObject job){
        text(box,"Recogida: "+job.optString("origin"),16,true);text(box,"Entrega: "+job.optString("destination"),16,true);
        text(box,job.optString("service_type")+" · "+ClientRules.vehicle(job.optString("vehicle_type")),15,false);
        text(box,job.optString("distance_km")+" km · Ayudantes: "+job.optInt("helpers"),15,false);text(box,money(job.optDouble("price")),25,true).setTextColor(TEAL);
    }
    private void renderActive(ClientApi.Tracking tracking,boolean trackingError){
        screen="home";shell();trackingStatus=null;originField=null;destField=null;quoteArea=null;
        JSONObject job=active;var box=card("Tu servicio");text(box,ClientRules.status(job.optString("status")),19,true);details(box,job);
        if("requested".equals(job.optString("status"))&&!job.optString("release_reason","").isEmpty()&&!job.isNull("release_reason"))text(box,"El fletero liberó el servicio. Buscando otro. Motivo: "+job.optString("release_reason"),14,false);
        if("requested".equals(job.optString("status"))&&job.isNull("driver_id"))button(box,"Cancelar solicitud",()->dialog().setTitle("¿Cancelar la solicitud?").setMessage("Solo puedes cancelar antes de que un fletero acepte. Quedará en tu historial.").setNegativeButton("Volver",null).setPositiveButton("Cancelar solicitud",(d,w)->task(()->api.cancel(job.optString("id")),result->{active=null;clearTrackingMap();refresh();})).show());
        if(ClientRules.assigned(job.optString("status"))){
            var driverBox=card("Tu fletero asignado");var driver=tracking.driver();var fix=tracking.fix();
            if(driver!=null){text(driverBox,driver.optString("full_name","Sin nombre"),18,true);text(driverBox,"Vehículo: "+ClientRules.vehicle(driver.optString("vehicle_type")),15,false);text(driverBox,"Placas: "+driver.optString("plates","Sin registrar"),16,true);}else text(driverBox,trackingError?"No se pudo actualizar la identificación del fletero.":"Consultando la identificación del fletero…",15,false);
            if(fix!=null){trackingStatus=text(driverBox,ClientRules.freshness(fix),16,true);text(driverBox,"Precisión: "+Math.round(fix.optDouble("accuracy",0))+" m",14,false);text(driverBox,"Última recepción: "+fix.optString("updated_at"),12,false);}else trackingStatus=text(driverBox,trackingError?"No se pudo actualizar la ubicación. Reintenta el seguimiento.":"Esperando ubicación del fletero…",15,false);
        }
        var mapBox=card("Ruta del servicio");routeContainer=mapBox;routeMessage=text(mapBox,"",14,false);currentTrackingFix=trackingError?null:tracking.fix();
        String key=api.userId()+"|"+job.optString("id")+"|"+job.optString("origin")+"|"+job.optString("destination");
        if(!key.equals(routeKey)){clearTrackingMap();routeKey=key;}
        if(trackingMap!=null){attachMap(mapBox);trackingMap.updateDriver(trackingError?null:tracking.fix());routeMessage.setText("Recogida → Entrega · El punto azul indica al fletero; naranja, ubicación desactualizada.");}
        else if(!routeLoading&&!routeFailed)loadTrackingRoute(job,key);
        else routeMessage.setText(routeFailed?"No se pudo cargar la ruta. Pulsa Recargar mapa.":"Cargando ruta…");
        if(trackingMap!=null&&tracking.fix()!=null)button(mapBox,"Ver fletero en mapa",()->trackingMap.centerDriver());
        button(mapBox,"Recargar mapa",()->{clearTrackingMap();refresh();});button(root,"Actualizar seguimiento",this::refresh);message.setText("");
    }
    private void attachMap(LinearLayout box){if(trackingMap.getParent() instanceof ViewGroup parent)parent.removeView(trackingMap);box.addView(trackingMap,new LinearLayout.LayoutParams(-1,dp(280)));}
    private void loadTrackingRoute(JSONObject job,String key){
        routeLoading=true;
        long session=revision,request=++routeRevision;String user=api.userId();routeMessage.setText("Cargando ruta…");
        worker.execute(()->{try{JSONObject route=api.route(job.optString("origin"),job.optString("destination"));main.post(()->{
            if(isDestroyed()||session!=revision||request!=routeRevision||!user.equals(api.userId())||!"home".equals(screen)||active==null||!key.equals(routeKey))return;
            try{trackingMap=new ClientMapView(this);trackingMap.route(route.optString("polyline"));trackingMap.updateDriver(currentTrackingFix);attachMap(routeContainer);routeLoading=false;routeMessage.setText(route.optString("distance_km")+" km · "+route.optString("duration_text"));if(currentTrackingFix!=null)button(routeContainer,"Ver fletero en mapa",()->{if(trackingMap!=null)trackingMap.centerDriver();});message.setText("Mapa cargado.");}
            catch(Exception error){clearTrackingMap();routeKey=key;routeFailed=true;routeMessage.setText("No se pudo abrir el mapa. Pulsa Recargar mapa.");}
        });}catch(Exception error){main.post(()->{if(!isDestroyed()&&session==revision&&request==routeRevision&&key.equals(routeKey)&&"home".equals(screen)){routeLoading=false;routeFailed=true;routeMessage.setText("No se pudo cargar la ruta. Pulsa Recargar mapa.");}});}});
    }
    private void clearPreview(){if(previewMap!=null){if(previewMap.getParent() instanceof ViewGroup parent)parent.removeView(previewMap);previewMap.dispose();previewMap=null;}}
    private void clearTrackingMap(){routeRevision++;routeKey="";routeLoading=false;routeFailed=false;if(trackingMap!=null){if(trackingMap.getParent() instanceof ViewGroup parent)parent.removeView(trackingMap);trackingMap.dispose();trackingMap=null;}}
    private void disposeMaps(){clearPreview();clearTrackingMap();if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}}
    private void resetDraft(){originDraft="";destDraft="";vehicleChoice=0;helperChoice=0;serviceChoice=0;quote=null;requestId="";draftRevision++;originField=null;destField=null;quoteArea=null;}
    private void history(){task(()->api.history(historyPage*5),rows->{screen="history";shell();card("Historial de servicios");for(int i=0;i<Math.min(5,rows.length());i++){var job=rows.getJSONObject(i);var box=card(ClientRules.status(job.optString("status")));details(box,job);text(box,job.optString("created_at").split("T")[0],13,false);}if(rows.length()==0)text(root,"No hay servicios en esta página.",16,false);if(historyPage>0)button(root,"Anterior",()->{historyPage--;history();});if(rows.length()>5)button(root,"Ver más",()->{historyPage++;history();});button(root,"Volver al seguimiento",()->{screen="home";refresh();});message.setText("");});}
    private void profile(){task(api::profile,p->{screen="profile";shell();var box=card("Mi perfil de cliente");var name=field(box,"Nombre completo",p.optString("full_name"),InputType.TYPE_CLASS_TEXT|InputType.TYPE_TEXT_FLAG_CAP_WORDS);button(box,"Guardar perfil",()->task(()->{api.saveName(name.getText().toString());return true;},ok->message.setText("Perfil guardado.")));button(root,"Volver al seguimiento",()->{screen="home";refresh();});message.setText("");});}
    private AlertDialog.Builder dialog(){picking=true;return new AlertDialog.Builder(this).setOnDismissListener(d->picking=false);}
    private void logout(){dialog().setTitle("¿Cerrar sesión de cliente?").setMessage("Tu servicio seguirá guardado. La app del fletero conserva su propia sesión.").setNegativeButton("Volver",null).setPositiveButton("Cerrar sesión",(d,w)->{stopLocation();disposeMaps();task(()->{api.logout();return true;},ok->{revision++;login();});}).show();}
    private void open(String uri){try{startActivity(new Intent(Intent.ACTION_VIEW,Uri.parse(uri)));}catch(ActivityNotFoundException error){message.setText("No se pudo abrir el enlace.");}}
    private void picker(EditText target){
        picking=true;var box=new LinearLayout(this);box.setOrientation(LinearLayout.VERTICAL);box.setPadding(dp(12),dp(8),dp(12),dp(8));text(box,"Mueve el mapa hasta colocar el centro sobre el punto exacto. También puedes tocar un lugar.",15,false);
        try{pickerMap=new ClientMapView(this);pickerMap.picker(ClientRules.coordinates(target.getText().toString()));box.addView(pickerMap,new LinearLayout.LayoutParams(-1,dp(340)));
            long draft=draftRevision;pickerDialog=new AlertDialog.Builder(this).setTitle(target==originField?"Punto de recogida":"Punto de entrega").setView(box).setNegativeButton("Volver",null).setPositiveButton("Elegir este punto",null).create();
            pickerDialog.setOnShowListener(d->pickerDialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener(v->pickerMap.selected((lat,lng)->{if(draft==draftRevision&&"home".equals(screen)&&active==null)target.setText(String.format(Locale.US,"%.6f, %.6f",lat,lng));pickerDialog.dismiss();},()->Toast.makeText(this,"El mapa sigue cargando. Intenta de nuevo.",Toast.LENGTH_SHORT).show())));
            pickerDialog.setOnDismissListener(d->{picking=false;if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}pickerDialog=null;});pickerDialog.show();
        }catch(Exception error){picking=false;if(pickerMap!=null){pickerMap.dispose();pickerMap=null;}message.setText("No se pudo abrir el mapa. Puedes escribir una dirección.");}
    }
    private void locate(EditText target){
        stopLocation();locationTarget=target;locationRevision=draftRevision;
        if(checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)!=PackageManager.PERMISSION_GRANTED&&checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)!=PackageManager.PERMISSION_GRANTED){awaitingLocationPermission=true;requestPermissions(new String[]{Manifest.permission.ACCESS_FINE_LOCATION,Manifest.permission.ACCESS_COARSE_LOCATION},10);return;}
        startLocation();
    }
    @Override public void onRequestPermissionsResult(int code,String[] permissions,int[] results){super.onRequestPermissionsResult(code,permissions,results);if(code==10){awaitingLocationPermission=false;if(checkSelfPermission(Manifest.permission.ACCESS_COARSE_LOCATION)==PackageManager.PERMISSION_GRANTED||checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)==PackageManager.PERMISSION_GRANTED)startLocation();else {stopLocation();message.setText("Puedes elegir el punto en el mapa o escribir la dirección.");}}}
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
