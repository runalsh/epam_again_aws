#!/usr/bin/python3

import psycopg2
# import urllib.request as req
import os
# from os import environ,getenv
from os import getenv
from dotenv import load_dotenv
import sys
import json
import requests
# import logging
from time import time 
# from psycopg2 import Error
from flask import Flask,request,render_template,jsonify
import datetime
import psutil
from psutil import getloadavg

# from psutil import cpu_percent,getloadavg
# from prometheus_flask_exporter import PrometheusMetrics



host=getenv('HOSTNAME')
load_dotenv()

currtime = datetime.datetime.now()
current_time = currtime.strftime("%H:%M:%S")

# вариант под docker compose
# db= {"user": "pypostgres","password": "pypostgres","host": "postgres","port": "5432","database": "wandb"}
db = {
      "user": os.getenv('DB_USER'),
      "password": os.getenv('DB_PASSWORD'),
      "host": os.getenv('DB_HOST'),
      "port": os.getenv('DB_PORT'),
      "database": os.getenv('DB_NAME')
}

def storedata():
    connection = psycopg2.connect(**db)
    connection.autocommit = True
    # print('Connected')
    cursor = connection.cursor()
    create_clean = '''
        DROP table IF exists weather;
        CREATE table if not exists weather(id bigint PRIMARY KEY, weather_state_name varchar(16),wind_direction_compass varchar(5),created timestamp,applicable_date date, max_temp real, min_temp real, the_temp real);
        '''
    cursor.execute(create_clean)

    for day in range(1,31):
        response = requests.get("https://www.metaweather.com/api/location/2122265/"+str(currtime.year)+"/"+str(currtime.month)+"/"+str(day)+"/")
        for data in response.json():
            id = data['id']
            weather_state_name = data['weather_state_name'].strip('"')
            wind_direction_compass = data['wind_direction_compass'].strip('"')            
            created = data['created'].strip('"')
            applicable_date = data['applicable_date'].strip('"')
            max_temp = data['max_temp']
            min_temp = data['min_temp']
            the_temp = data['the_temp']
            
            cursor.execute("INSERT into weather values( %s, %s, %s, %s, %s, %s, %s, %s)", (id, weather_state_name, wind_direction_compass, created, applicable_date, max_temp, min_temp, the_temp))
    cursor.close()
    # connection.commit()
    connection.close()

def tablewipe():
    connection = psycopg2.connect(**db)
    connection.autocommit = True
    # print('Connected')
    cursor = connection.cursor()
    clean = '''
        DROP table IF exists weather;
        '''
    cursor.execute(clean)
    cursor.close()
    # connection.commit()
    connection.close()
    
# def allweather():
#     connection = psycopg2.connect(**db)
#     cursor = connection.cursor()
#     getalldata = '''
#         SELECT * FROM weather ORDER BY created;
#         '''
#     cursor.execute(getalldata)

#     record = cursor.fetchall()
#     columns = cursor.description
#     rows = '<tr>'
#     for row1 in columns:
#        rows += f'<td>{row1[0]}</td>'
#     rows += '</tr>'

#     for row in record:
#       rows += f"<tr>"
#       for col in row:
#         rows += f"<td>{col}</td>"
#       rows += f"</tr>"
#     data = '''
#     <html>
#     <style> table,  td {border:1px solid black; }td</style><body><table>%s</table></body></html>'''%(rows)
#     with open("index.html", "w") as file:
#         file.write(data)
#     file.close()
#     # print(data)
#     cursor.close()
#     # connection.commit()
#     connection.close()
#### убрал к херам, мб понадобится для дебага

def cpustress(seconds):
    assert type(seconds) == type(1) and seconds < 120
    start=time()
    while True:
        a=1
        while a < 1000:
            x=a*a
            x=1.3333*x/(a+7.7777)
            a+=1
        if (time() - start) > seconds:
            break

app = Flask(__name__)
app.config['SEND_FILE_MAX_AGE_DEFAULT'] = 0

# metrics = PrometheusMetrics(app)

@app.route('/back/ping')
def ping():
    answer = "PONG! %s im alive!" %(host)
    return jsonify(answer)
    
@app.route('/back/getdata')
def getdata():
    storedata()
    answer = "update completed at "+current_time
    return jsonify(answer)

@app.route('/back/cleandata')
def cleandata():
    tablewipe()
    answer = "table wiping completed at "+current_time
    return jsonify(answer)

# @app.route('/showmeallweather')
# def showmeallweather():
#     allweather()
#     return "index html from host %host ready at"+current_time

@app.route("/back/stress")
def stress():
    cpustress(10)
    answer = "Host %s stressed for 10 sec.\n" %(host)
    return jsonify(answer)

@app.route("/back/cpu")
def cpu():
    out=getloadavg()[0]
    answer = "Host: %s, CPU load: %s\n" %(host, out)
    return jsonify(answer)
    
@app.route('/back/showmeweather')
def showmeweather():
    date = request.args.get('date')
    # print(date)

    # logger.info(type(resp_weather))
    
    connection = psycopg2.connect(**db)
    cursor = connection.cursor()
    getalldata = '''SELECT * FROM weather WHERE applicable_date = '%s' ORDER BY created; '''% date
    # print (getalldata)
    cursor.execute(getalldata)

    record = cursor.fetchall()
    columns = cursor.description
    rows = '<tr>'
    for row1 in columns:
       rows += f'<td>{row1[0]}</td>'
    rows += '</tr>'

    for row in record:
      rows += f"<tr>"
      for col in row:
        rows += f"<td>{col}</td>"
      rows += f"</tr>"
    # print(rows)
    cursor.close()
    # connection.commit()
    connection.close()
    return jsonify(rows)

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
    app.run(debug=True)

