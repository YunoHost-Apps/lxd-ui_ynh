LXD only reads where its web interface lives when it starts. Installing this app
therefore **restarts the LXD daemon once**, which stops the running containers
and virtual machines. Removing the app does not restart it.
