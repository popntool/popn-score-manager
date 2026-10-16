const VERSION="3.3.71";

async function fetchPartial(name){
  const response=await fetch(`./partials/${name}.html?v=${VERSION}`,{cache:"no-store"});
  if(!response.ok)throw new Error(`${name}.html: HTTP ${response.status}`);
  return await response.text();
}

async function boot(){
  try{
    window.psmLoading?.status("画面を準備しています");

    // User UI is split from index.html. Admin HTML is isolated in admin-only partials.
    const [auth,app,dialogs,adminMenu,adminPanel,adminDialog]=await Promise.all([
      fetchPartial("auth-gate"),
      fetchPartial("app-shell"),
      fetchPartial("dialogs"),
      fetchPartial("admin-menu"),
      fetchPartial("admin-panel"),
      fetchPartial("admin-dialog")
    ]);

    document.querySelector("#authMount").innerHTML=auth;
    document.querySelector("#appMount").innerHTML=app;
    document.querySelector("#dialogsMount").innerHTML=dialogs;

    // These mounts are hidden by their own admin-only/tab-panel state until app.js
    // confirms that the signed-in account is an administrator.
    document.querySelector("#adminMenuMount").innerHTML=adminMenu;
    document.querySelector("#adminPanelMount").innerHTML=adminPanel;
    document.querySelector("#adminDialogMount").innerHTML=adminDialog;

    const {checkOnLaunch,watchForUpdates}=await import(`./version-check.js?v=${VERSION}`);
    if(await checkOnLaunch())return;
    watchForUpdates();
    await import(`./app.js?v=${VERSION}`);
  }catch(error){
    console.error("Application bootstrap failed:",error);
    window.psmLoading?.error(error);
  }
}

boot();
