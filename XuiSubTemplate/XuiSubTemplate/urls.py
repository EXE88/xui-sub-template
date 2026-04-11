from django.contrib import admin
from django.urls import path, include
from django.conf import settings

urlpatterns = [
    path(f'{settings.ADMIN_PATH}/', admin.site.urls),
    path('sub/', include('sub.urls')),
]
