# The Base Image used to create this Image
FROM httpd:latest

# Install ping, curl
RUN apt update \
 && apt install -y iputils-ping curl \
 && rm -rf /var/lib/apt/lists/*

# to Copy a file named httpd.conf from present working directory to the /usr/local/apache2/conf inside the container
# I have taken the Standard httpd.conf file and enabled the necassary modules and adding Support for an additional Directory
COPY httpd.conf /usr/local/apache2/conf/httpd.conf

# This is the Additional Directory where we are going to keep our Virtualhost configuraiton files
# You can use the image to create N number of different virtual hosts
RUN mkdir -p /usr/local/apache2/conf/sites/
COPY apacheconf/sites/testlocal.conf /usr/local/apache2/conf/sites/testlocal.conf

# Static content for the test.local Virtualhost DocumentRoot
COPY apacheconf/htmlfiles/ /usr/local/apache2/testlocal/

# To tell docker to expose this port
EXPOSE 80

# The Base command, This command should be used to start the container
# Remember, A Container is a Process.As long as the base process (started by base cmd) is live the Container will be ALIVE.
CMD ["httpd", "-D", "FOREGROUND"]