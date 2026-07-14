// An easter egg, not a pattern. Five clicks on the logo and the console
// remembers what a cloud actually is. Resets on reload.
(function () {
  var logo = document.getElementById("logo");
  if (!logo) return;
  var clicks = 0;
  logo.style.cursor = "pointer";
  logo.addEventListener("click", function () {
    if (++clicks < 5) return;
    logo.textContent = "🏠 Cloudbox Console";
    var footer = document.querySelector("footer");
    if (footer) {
      footer.textContent =
        "the cloud is just someone else's computer. this one is yours.";
    }
  });
})();
