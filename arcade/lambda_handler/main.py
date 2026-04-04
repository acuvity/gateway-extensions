from mangum import Mangum

from hooks.server import app

handler = Mangum(app, lifespan="off")
