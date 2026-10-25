import os

from app import create_app

app = create_app()

if __name__ == '__main__':
    # PORT: defaults to 5050 (macOS AirPlay uses 5000). The Flutter app
    #       defaults to 5050 too; see README.md for emulator / phone setup.
    # HOST: set to 0.0.0.0 only when testing on a real phone on the same Wi-Fi.
    #       Debug mode is turned off then, because the debugger must never be
    #       reachable from other devices.
    host = os.getenv('HOST', '127.0.0.1')
    app.run(
        host=host,
        port=int(os.getenv('PORT', '5050')),
        debug=host in ('127.0.0.1', 'localhost'),
        # The blockchain worker is a thread in this process; the reloader
        # would start a second copy of it.
        use_reloader=False,
    )
