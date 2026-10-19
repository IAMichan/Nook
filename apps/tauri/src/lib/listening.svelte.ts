// Of er nu geluisterd wordt (praten tegen Nook), gedeeld door de microfoonknop en de balk.
class Listening {
  active = $state(false);

  toggle() {
    this.active = !this.active;
  }

  start() {
    this.active = true;
  }

  stop() {
    this.active = false;
  }
}

export const listening = new Listening();
