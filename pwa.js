let deferredInstallPrompt=null;
const installButton=document.getElementById('installApp');
const networkBadge=document.getElementById('networkStatus');

function updateNetworkStatus(){
  const online=navigator.onLine;
  document.documentElement.dataset.network=online?'online':'offline';
  if(networkBadge){
    networkBadge.textContent=online?'En línea':'Sin conexión';
    networkBadge.className=online?'network online':'network offline';
  }
  document.querySelectorAll('[data-requires-online]').forEach(el=>{
    el.disabled=!online;
    el.title=online?'':'Se requiere conexión para validar esta acción en Supabase.';
  });
}
window.addEventListener('online',updateNetworkStatus);
window.addEventListener('offline',updateNetworkStatus);
updateNetworkStatus();

window.addEventListener('beforeinstallprompt',event=>{
  event.preventDefault(); deferredInstallPrompt=event;
  if(installButton) installButton.hidden=false;
});
if(installButton){
  installButton.addEventListener('click',async()=>{
    if(!deferredInstallPrompt) return;
    deferredInstallPrompt.prompt(); await deferredInstallPrompt.userChoice;
    deferredInstallPrompt=null; installButton.hidden=true;
  });
}
window.addEventListener('appinstalled',()=>{if(installButton) installButton.hidden=true;});

if('serviceWorker' in navigator){
  window.addEventListener('load',async()=>{
    try{
      const registration=await navigator.serviceWorker.register('./service-worker.js',{scope:'./'});
      registration.addEventListener('updatefound',()=>{
        const worker=registration.installing;
        if(!worker) return;
        worker.addEventListener('statechange',()=>{
          if(worker.state==='installed' && navigator.serviceWorker.controller){
            const bar=document.createElement('div');
            bar.className='update-bar';
            bar.innerHTML='Hay una actualización disponible. <button id="reloadPwa">Actualizar</button>';
            document.body.appendChild(bar);
            document.getElementById('reloadPwa').onclick=()=>{worker.postMessage('SKIP_WAITING');};
          }
        });
      });
      navigator.serviceWorker.addEventListener('controllerchange',()=>location.reload());
    }catch(error){console.error('No se pudo registrar la PWA:',error);}
  });
}
