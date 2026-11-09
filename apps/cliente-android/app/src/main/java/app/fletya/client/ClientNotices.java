package app.fletya.client;
final class ClientNotices {
    static String title(String type){
        if(type==null)return "";
        return switch(type){case "client_requested"->"Solicitud registrada";case "client_assigned"->"Fletero asignado";case "client_arrived_pickup"->"El fletero llegó a recogida";case "client_picked_up"->"Carga recogida";case "client_arrived_delivery"->"El fletero llegó a entrega";case "client_completed"->"Servicio completado";case "client_cancelled"->"Solicitud cancelada";case "client_released"->"Buscando otro fletero";default->"";};
    }
    static boolean matchesPush(String signedInUser,String registeredUser,String nonce,String recipient,String messageNonce,String type,String id){
        if(signedInUser==null||signedInUser.isEmpty()||!signedInUser.equals(registeredUser)||!signedInUser.equals(recipient)||nonce==null||nonce.isEmpty()||!nonce.equals(messageNonce)||title(type).isEmpty())return false;
        try{return java.util.UUID.fromString(id).toString().equals(id.toLowerCase(java.util.Locale.ROOT));}catch(RuntimeException error){return false;}
    }
    static String time(String value){try{return java.time.OffsetDateTime.parse(value).atZoneSameInstant(java.time.ZoneId.of("America/Cancun")).format(java.time.format.DateTimeFormatter.ofPattern("d/M/yyyy h:mm a",java.util.Locale.forLanguageTag("es-MX")));}catch(Exception error){return "Hora no disponible";}}
}
