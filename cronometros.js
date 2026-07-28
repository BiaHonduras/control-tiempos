import { supabase, obtenerSesion, cerrarSesion } from './supabase-config.js';

const empleados=['Santos Joya','Carlos Zelaya','Arnold Miranda','Martin Enamorado'];
const actividades=['Limpieza - Andén','Limpieza - Parqueo','Limpieza - Bodega','Limpieza - Área Externa','Limpieza - Bodega 095','Limpieza - Bodega 033','Ordenamiento de Bodega','Rotulación de Ingresos'];
const tipos=['Café','Representada','Mixto'];
const timers=new Map();

const slug=s=>s.normalize('NFD').replace(/[\u0300-\u036f]/g,'').replace(/\W+/g,'-').toLowerCase();
const fmt=s=>{s=Math.max(0,Number(s||0));return [Math.floor(s/3600),Math.floor((s%3600)/60),s%60].map(v=>String(v).padStart(2,'0')).join(':')};
const hoy=()=>new Date().toISOString().slice(0,10);
const esc=s=>String(s??'').replace(/[&<>"']/g,m=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#039;'}[m]));

function segundosActuales(t){
  if(!t) return 0;
  const base=Number(t.segundos_acumulados||0);
  if(t.estado==='ejecucion' && t.inicio) return base+Math.max(0,Math.floor((Date.now()-new Date(t.inicio).getTime())/1000));
  return base;
}
function tarjetaPrep(emp){
 const id=slug(emp);
 return `<article class="worker" id="card-prep-${id}"><h3>${emp}</h3><div class="form">
 <div><label>Fecha</label><input id="prep-fecha-${id}" type="date" value="${hoy()}"></div>
 <div><label>Zona</label><input id="prep-zona-${id}" placeholder="Zona o gira"></div>
 <div><label>Tipo</label><select id="prep-tipo-${id}"><option value="">Seleccione</option>${tipos.map(x=>`<option>${x}</option>`).join('')}</select></div>
 <div><label>Facturas</label><input id="prep-facturas-${id}" type="number" min="1"></div>
 <div><label>Libras de la gira</label><input id="prep-libras-${id}" type="number" min="0" step=".01"></div></div>
 <div class="timer" id="timer-prep-${id}">00:00:00</div><div class="desc" id="desc-prep-${id}">Sin preparación activa</div>
 <div class="conflict" id="conflict-prep-${id}"></div>
 <div class="actions"><button class="primary" data-requires-online data-action="start" data-cat="preparacion" data-emp="${emp}">Iniciar</button><button class="warn" data-requires-online data-action="pause" data-cat="preparacion" data-emp="${emp}">Pausar</button><button class="primary" data-requires-online data-action="resume" data-cat="preparacion" data-emp="${emp}">Continuar</button><button class="ok" data-requires-online data-action="finish" data-cat="preparacion" data-emp="${emp}">Finalizar</button><button class="danger" data-requires-online data-action="cancel" data-cat="preparacion" data-emp="${emp}">Cancelar</button></div></article>`;
}
function tarjetaAct(emp){
 const id=slug(emp);
 return `<article class="worker" id="card-act-${id}"><h3>${emp}</h3><div class="form">
 <div><label>Fecha</label><input id="act-fecha-${id}" type="date" value="${hoy()}"></div>
 <div style="grid-column:span 2"><label>Actividad</label><select id="act-tipo-${id}"><option value="">Seleccione</option>${actividades.map(x=>`<option>${x}</option>`).join('')}</select></div></div>
 <div class="timer" id="timer-act-${id}">00:00:00</div><div class="desc" id="desc-act-${id}">Sin actividad activa</div>
 <div class="conflict" id="conflict-act-${id}"></div>
 <div class="actions"><button class="primary" data-requires-online data-action="start" data-cat="actividad" data-emp="${emp}">Iniciar</button><button class="warn" data-requires-online data-action="pause" data-cat="actividad" data-emp="${emp}">Pausar</button><button class="primary" data-requires-online data-action="resume" data-cat="actividad" data-emp="${emp}">Continuar</button><button class="ok" data-requires-online data-action="finish" data-cat="actividad" data-emp="${emp}">Finalizar</button><button class="danger" data-requires-online data-action="cancel" data-cat="actividad" data-emp="${emp}">Cancelar</button></div></article>`;
}
document.getElementById('prepWorkers').innerHTML=empleados.map(tarjetaPrep).join('');
document.getElementById('actWorkers').innerHTML=empleados.map(tarjetaAct).join('');

function datosFormulario(cat,emp){
 const id=slug(emp);
 if(cat==='preparacion'){
  const d={fecha_preparacion:document.getElementById(`prep-fecha-${id}`).value,zona:document.getElementById(`prep-zona-${id}`).value.trim(),tipo:document.getElementById(`prep-tipo-${id}`).value,facturas:Number(document.getElementById(`prep-facturas-${id}`).value||0),libras:Number(document.getElementById(`prep-libras-${id}`).value||0)};
  if(!d.fecha_preparacion||!d.zona||!d.tipo||d.facturas<=0||d.libras<0) throw new Error('Complete fecha, zona, tipo, facturas y libras.');
  return d;
 }
 const d={fecha:document.getElementById(`act-fecha-${id}`).value,actividad:document.getElementById(`act-tipo-${id}`).value};
 if(!d.fecha||!d.actividad) throw new Error('Seleccione fecha y actividad.');
 return d;
}
function mostrarConflicto(cat,emp,msg){
 const id=slug(emp),el=document.getElementById(`conflict-${cat==='preparacion'?'prep':'act'}-${id}`);
 el.textContent=msg;el.style.display='block';setTimeout(()=>el.style.display='none',6000);
}
async function rpc(nombre,args){
 const {data,error}=await supabase.rpc(nombre,args);
 if(error) throw error;
 return data;
}
async function iniciar(cat,emp){
 if(!navigator.onLine){mostrarConflicto(cat,emp,'Sin conexión. La operación debe validarse en Supabase.');return}
 try{
  const data=await rpc('iniciar_cronometro',{p_categoria:cat,p_empleado:emp,p_datos:datosFormulario(cat,emp)});
  await cargarTodo();
 }catch(e){mostrarConflicto(cat,emp,e.message.includes('already exists')?'Ya existe un cronómetro activo para este colaborador.':e.message)}
}
async function accionar(cat,emp,accion){
 if(!navigator.onLine){mostrarConflicto(cat,emp,'Sin conexión. La operación debe validarse en Supabase.');return}
 const t=timers.get(`${cat}|${emp}`);
 if(!t){mostrarConflicto(cat,emp,'No existe un cronómetro activo.');return}
 try{
  if(accion==='finish') await rpc('finalizar_cronometro',{p_id:t.id,p_expected_version:t.version});
  else if(accion==='cancel') await rpc('cancelar_cronometro',{p_id:t.id,p_expected_version:t.version});
  else await rpc('cambiar_estado_cronometro',{p_id:t.id,p_expected_version:t.version,p_accion:accion});
  await cargarTodo();
 }catch(e){
  mostrarConflicto(cat,emp,'Este cronómetro fue modificado desde otro dispositivo. Se actualizará con la versión vigente.');
  await cargarTodo();
 }
}
document.addEventListener('click',e=>{
 const b=e.target.closest('button[data-action]');if(!b)return;
 const {action,cat,emp}=b.dataset;
 if(action==='start') iniciar(cat,emp); else accionar(cat,emp,action);
});

function aplicarTimer(t){
 const key=`${t.categoria}|${t.empleado}`;timers.set(key,t);
 const id=slug(t.empleado),pref=t.categoria==='preparacion'?'prep':'act';
 const card=document.getElementById(`card-${pref}-${id}`);if(!card)return;
 card.classList.add('active');
 document.getElementById(`timer-${pref}-${id}`).textContent=fmt(segundosActuales(t));
 const d=t.datos||{};
 document.getElementById(`desc-${pref}-${id}`).textContent=t.estado==='pausado'?'Pausado':(t.categoria==='preparacion'?`${d.zona||''} | ${d.tipo||''} | ${d.facturas||0} facturas | ${Number(d.libras||0).toFixed(2)} lb`:d.actividad||'Actividad activa');
 if(t.categoria==='preparacion'){
  document.getElementById(`prep-fecha-${id}`).value=d.fecha_preparacion||hoy();document.getElementById(`prep-zona-${id}`).value=d.zona||'';document.getElementById(`prep-tipo-${id}`).value=d.tipo||'';document.getElementById(`prep-facturas-${id}`).value=d.facturas||'';document.getElementById(`prep-libras-${id}`).value=d.libras||'';
 }else{document.getElementById(`act-fecha-${id}`).value=d.fecha||hoy();document.getElementById(`act-tipo-${id}`).value=d.actividad||''}
}
function limpiarTarjetas(){
 timers.clear();
 empleados.forEach(emp=>['prep','act'].forEach(pref=>{
  const id=slug(emp),card=document.getElementById(`card-${pref}-${id}`);card.classList.remove('active');
  document.getElementById(`timer-${pref}-${id}`).textContent='00:00:00';
  document.getElementById(`desc-${pref}-${id}`).textContent=pref==='prep'?'Sin preparación activa':'Sin actividad activa';
 }));
}
async function cargarTodo(){
 const [{data:activos,error:e1},{data:prep,error:e2},{data:acts,error:e3}]=await Promise.all([
  supabase.from('cronometros').select('*').in('estado',['ejecucion','pausado']),
  supabase.from('historial_preparaciones').select('*').order('created_at',{ascending:false}).limit(200),
  supabase.from('historial_actividades').select('*').order('created_at',{ascending:false}).limit(200)
 ]);
 if(e1||e2||e3) throw e1||e2||e3;
 limpiarTarjetas();(activos||[]).forEach(aplicarTimer);
 document.getElementById('prepHistory').innerHTML=(prep||[]).map(r=>`<tr><td>${new Date(r.created_at).toLocaleString('es-HN')}</td><td>${esc(r.empleado)}</td><td>${esc(r.zona)}</td><td>${esc(r.tipo)}</td><td>${r.facturas}</td><td>${Number(r.libras).toFixed(2)}</td><td>${fmt(r.segundos)}</td><td>${esc(r.finalizado_por_email||'')}</td></tr>`).join('');
 document.getElementById('actHistory').innerHTML=(acts||[]).map(r=>`<tr><td>${new Date(r.created_at).toLocaleString('es-HN')}</td><td>${esc(r.empleado)}</td><td>${esc(r.actividad)}</td><td>${fmt(r.segundos)}</td><td>${esc(r.finalizado_por_email||'')}</td></tr>`).join('');
 document.getElementById('conexion').textContent='Conectado. Datos sincronizados con Supabase.';
}
setInterval(()=>timers.forEach(t=>{
 const id=slug(t.empleado),pref=t.categoria==='preparacion'?'prep':'act',el=document.getElementById(`timer-${pref}-${id}`);
 if(el)el.textContent=fmt(segundosActuales(t));
}),1000);

const ses=await obtenerSesion();
if(!ses.ok||!ses.session) location.replace('./index.html');
else document.getElementById('userEmail').textContent=ses.session.user.email||'Usuario';

window.salir=async()=>{await cerrarSesion();location.replace('./index.html')};

const canal=supabase.channel('cronometros-operacion')
 .on('postgres_changes',{event:'*',schema:'public',table:'cronometros'},()=>cargarTodo())
 .on('postgres_changes',{event:'*',schema:'public',table:'historial_preparaciones'},()=>cargarTodo())
 .on('postgres_changes',{event:'*',schema:'public',table:'historial_actividades'},()=>cargarTodo())
 .subscribe();

try{await cargarTodo()}catch(e){document.getElementById('conexion').textContent='No se pudo cargar la información: '+e.message}
