from django.urls import path
from . import views

urlpatterns = [
	path('<str:subid>/', views.SubView.as_view(), name='sub_view'),
]
